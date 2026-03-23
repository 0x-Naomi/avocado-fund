// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAvocadoVault} from "./interfaces/IAvocadoVault.sol";

/// @title AvocadoVault
/// @author Avocado Labs
/// @notice ERC4626-compliant USDC vault. Depositors supply USDC and receive
///         avUSDC shares representing their proportional claim on vault assets.
///         Capital is deployed to the AvocadoLending contract where it earns
///         interest from borrowers. The vault tracks idle vs deployed capital
///         and adjusts share price accordingly as interest accrues.
///
/// @dev Inherits OpenZeppelin ERC4626. Key design decisions:
///      - Share price increases as interest accrues (no rebasing)
///      - A configurable cap prevents unbounded growth during launch phase
///      - A targetIdleRatio keeps some USDC liquid for immediate withdrawals
///      - Performance fee (in bps) is taken from interest on fee collection
///      - Two-step ownership transfer via Ownable2Step
contract AvocadoVault is ERC4626, Ownable2Step, Pausable, IAvocadoVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant MAX_CAP = 100_000_000e6;      // $100M hard cap
    uint16  public constant MAX_FEE_BPS = 2_000;          // 20% max performance fee
    uint16  public constant BPS_DENOMINATOR = 10_000;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @inheritdoc IAvocadoVault
    uint256 public vaultCap;

    /// @inheritdoc IAvocadoVault
    uint256 public deployedAssets;

    /// @inheritdoc IAvocadoVault
    address public lendingContract;

    /// @inheritdoc IAvocadoVault
    uint16 public performanceFeeBps;

    /// @inheritdoc IAvocadoVault
    address public feeRecipient;

    /// @inheritdoc IAvocadoVault
    uint16 public targetIdleRatio;

    /// @inheritdoc IAvocadoVault
    uint256 public accruedInterest;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _usdc           Address of the USDC token (6 decimals)
    /// @param _owner          Initial owner (governance / multisig)
    /// @param _feeRecipient   Address to receive performance fees
    /// @param _initialCap     Initial vault cap in USDC (6 decimals)
    constructor(
        address _usdc,
        address _owner,
        address _feeRecipient,
        uint256 _initialCap
    )
        ERC4626(IERC20(_usdc))
        ERC20("Avocado USDC", "avUSDC")
        Ownable(_owner)
    {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
        vaultCap = _initialCap;
        performanceFeeBps = 500; // 5% default
        targetIdleRatio = 1_000; // 10% idle default
    }

    // ─── ERC4626 overrides ────────────────────────────────────────────────────

    /// @notice Total assets = idle USDC in vault + deployed to lending + accrued interest
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return idle + deployedAssets;
    }

    /// @notice Enforce vault cap and pause state on deposits
    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (paused()) return 0;
        uint256 current = totalAssets();
        if (current >= vaultCap) return 0;
        return vaultCap - current;
    }

    /// @notice Enforce vault cap on mints
    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 maxDep = maxDeposit(receiver);
        if (maxDep == 0) return 0;
        return convertToShares(maxDep);
    }

    /// @notice Enforce available liquidity on withdrawals
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 ownerAssets = convertToAssets(balanceOf(owner));
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return ownerAssets.min(idle);
    }

    /// @notice Enforce available liquidity on redeems
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 maxWith = maxWithdraw(owner);
        return convertToShares(maxWith);
    }

    // ─── Internal deposit/withdraw hooks ─────────────────────────────────────

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override whenNotPaused {
        uint256 cap = vaultCap;
        uint256 current = totalAssets();
        if (current + assets > cap) revert VaultCapExceeded(assets, cap - current);
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientLiquidity(idle, assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ─── Capital management ───────────────────────────────────────────────────

    /// @notice Deploy idle USDC to the lending contract
    /// @dev Keeps targetIdleRatio of total assets idle for withdrawals
    function deployToLending(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        address lending = lendingContract;
        if (lending == address(0)) revert ZeroAddress();

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (amount > idle) revert InsufficientLiquidity(idle, amount);

        deployedAssets += amount;
        IERC20(asset()).safeTransfer(lending, amount);
        emit FundsDeployed(lending, amount);
    }

    /// @notice Recall USDC from the lending contract back to the vault
    function recallFromLending(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        address lending = lendingContract;
        if (lending == address(0)) revert ZeroAddress();
        if (amount > deployedAssets) revert InsufficientLiquidity(deployedAssets, amount);

        deployedAssets -= amount;
        // Lending contract must have approved this vault to pull funds
        IERC20(asset()).safeTransferFrom(lending, address(this), amount);
        emit FundsRecalled(lending, amount);
    }

    /// @notice Called by the lending contract to report interest earned
    /// @dev Increases deployedAssets, which increases totalAssets() and share price
    function reportInterest(uint256 interestAmount) external {
        if (msg.sender != lendingContract) revert OnlyLending();
        deployedAssets += interestAmount;
        accruedInterest += interestAmount;
    }

    // ─── Fee management ───────────────────────────────────────────────────────

    /// @notice Collect performance fees on accrued interest
    /// @dev Mints shares to the fee recipient rather than transferring USDC
    ///      (avoids liquidity drain; fee recipient redeems at will)
    function collectFees() external {
        uint256 interest = accruedInterest;
        if (interest == 0) return;

        uint256 feeAmount = (interest * performanceFeeBps) / BPS_DENOMINATOR;
        if (feeAmount == 0) return;

        accruedInterest = 0;

        // S-02 fix: compute feeShares BEFORE reducing deployedAssets
        // to prevent share dilution from lowered totalAssets()
        uint256 feeShares = convertToShares(feeAmount);

        // Reduce deployedAssets AFTER share conversion
        if (feeAmount <= deployedAssets) {
            deployedAssets -= feeAmount;
        }

        // Mint fee shares to recipient
        _mint(feeRecipient, feeShares);

        emit FeesCollected(feeRecipient, feeAmount);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @inheritdoc IAvocadoVault
    function setVaultCap(uint256 newCap) external onlyOwner {
        if (newCap > MAX_CAP) revert VaultCapExceeded(newCap, MAX_CAP);
        emit VaultCapUpdated(vaultCap, newCap);
        vaultCap = newCap;
    }

    /// @inheritdoc IAvocadoVault
    function setLendingContract(address newLending) external onlyOwner {
        if (newLending == address(0)) revert ZeroAddress();
        emit LendingContractUpdated(lendingContract, newLending);
        lendingContract = newLending;
    }

    /// @inheritdoc IAvocadoVault
    function setPerformanceFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFee(newFeeBps);
        emit PerformanceFeeUpdated(performanceFeeBps, newFeeBps);
        performanceFeeBps = newFeeBps;
    }

    /// @inheritdoc IAvocadoVault
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
    }

    /// @notice Set the target idle ratio (basis points)
    function setTargetIdleRatio(uint16 newRatio) external onlyOwner {
        if (newRatio > BPS_DENOMINATOR) revert InvalidFee(newRatio);
        targetIdleRatio = newRatio;
    }

    /// @inheritdoc IAvocadoVault
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IAvocadoVault
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @notice S-01 fix: Virtual share offset to mitigate first-depositor inflation attack.
    ///         With USDC (6 decimals), this makes the attack economically infeasible.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ─── Bad debt ─────────────────────────────────────────────────────────────

    /// @notice Called by lending contract to write down bad debt (reduces deployedAssets without USDC transfer)
    /// @param amount The amount of bad debt to write down
    function writeDownBadDebt(uint256 amount) external {
        if (msg.sender != lendingContract) revert OnlyLending();
        if (amount > deployedAssets) {
            deployedAssets = 0;
        } else {
            deployedAssets -= amount;
        }
        emit FundsRecalled(lendingContract, amount);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /// @notice Compute optimal deploy amount = totalAssets * (1 - targetIdleRatio) - deployedAssets
    function optimalDeployAmount() external view returns (uint256) {
        uint256 total = totalAssets();
        uint256 targetDeployed = total * (BPS_DENOMINATOR - targetIdleRatio) / BPS_DENOMINATOR;
        if (targetDeployed <= deployedAssets) return 0;
        return targetDeployed - deployedAssets;
    }

    /// @notice Current utilization rate (deployed / total), in basis points
    function utilizationBps() external view returns (uint256) {
        uint256 total = totalAssets();
        if (total == 0) return 0;
        return (deployedAssets * BPS_DENOMINATOR) / total;
    }

    /// @notice Current share price in USDC (6 decimals), scaled by 1e6
    /// @dev With _decimalsOffset()=6, shares have 12 decimals, so we scale by 1e12
    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6; // Initial price = $1.00
        return (totalAssets() * 1e12) / supply;
    }
}
