// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IAvocadoVault
/// @notice Interface for the Avocado Fund ERC4626 USDC Vault
interface IAvocadoVault is IERC4626 {
    // ─── Events ──────────────────────────────────────────────────────────────

    /// @notice Emitted when the vault cap is updated
    event VaultCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the lending contract is updated
    event LendingContractUpdated(address oldLending, address newLending);

    /// @notice Emitted when the performance fee is updated
    event PerformanceFeeUpdated(uint16 oldFee, uint16 newFee);

    /// @notice Emitted when fees are collected to the fee recipient
    event FeesCollected(address indexed recipient, uint256 amount);

    /// @notice Emitted when funds are deployed to the lending contract
    event FundsDeployed(address indexed lending, uint256 amount);

    /// @notice Emitted when funds are recalled from the lending contract
    event FundsRecalled(address indexed lending, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error VaultCapExceeded(uint256 requested, uint256 cap);
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientLiquidity(uint256 available, uint256 requested);
    error InvalidFee(uint16 fee);
    error OnlyLending();
    error Unauthorized();
    error NotPaused();
    error AlreadyPaused();

    // ─── View functions ───────────────────────────────────────────────────────

    /// @notice Maximum total assets the vault will accept
    function vaultCap() external view returns (uint256);

    /// @notice Amount currently deployed to the lending contract
    function deployedAssets() external view returns (uint256);

    /// @notice Address of the lending contract
    function lendingContract() external view returns (address);

    /// @notice Protocol performance fee in basis points (e.g. 1000 = 10%). Launch default is 10%.
    function performanceFeeBps() external view returns (uint16);

    /// @notice Address that receives protocol fees
    function feeRecipient() external view returns (address);

    /// @notice Ratio of idle USDC to keep in vault (basis points, e.g. 1000 = 10%)
    function targetIdleRatio() external view returns (uint16);

    /// @notice Total interest accrued since last fee collection
    function accruedInterest() external view returns (uint256);

    // ─── Admin functions ──────────────────────────────────────────────────────

    /// @notice Set the maximum cap for total vault assets
    function setVaultCap(uint256 newCap) external;

    /// @notice Set the lending contract address
    function setLendingContract(address newLending) external;

    /// @notice Set the performance fee in basis points
    function setPerformanceFee(uint16 newFeeBps) external;

    /// @notice Set the fee recipient address
    function setFeeRecipient(address newRecipient) external;

    /// @notice Deploy idle USDC to the lending contract
    function deployToLending(uint256 amount) external;

    /// @notice Recall USDC from lending contract
    function recallFromLending(uint256 amount) external;

    /// @notice Collect accrued protocol fees
    function collectFees() external;

    /// @notice Write down bad debt from a defaulted borrower (reduces deployedAssets without USDC transfer)
    /// @param amount The amount of bad debt to write down
    function writeDownBadDebt(uint256 amount) external;

    /// @notice Pause the vault (emergency only)
    function pause() external;

    /// @notice Unpause the vault
    function unpause() external;
}
