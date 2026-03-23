// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AVOToken mint interface
interface IAVOToken {
    function mint(address to, uint256 amount) external;
}

/// @title VaultRewards
/// @author Avocado Labs
/// @notice Distributes AVO token emissions to users who stake avUSDC vault shares.
///         Emission rate is dynamic — it decreases as TVL grows, smoothing APY.
///
/// @dev Based on the Sushi MasterChef v2 reward accounting pattern.
///      Users deposit avUSDC shares → earn AVO proportional to their stake.
///
///      Dynamic emission formula:
///        effectiveRate = baseEmissionPerSecond × scaleFactor / (totalStaked + scaleFactor)
///      When staked is low, emission approaches baseEmission.
///      When staked is high, emission tapers down → stable APY regardless of TVL.
contract VaultRewards is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Structs ───────────────────────────────────────────────────────────────

    struct UserInfo {
        uint256 amount;        // avUSDC staked
        uint256 rewardDebt;    // accumulated reward debt for proper accounting
    }

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice The AVO reward token (mintable)
    IAVOToken public immutable avoToken;

    /// @notice The avUSDC vault share token that users stake
    IERC20 public immutable stakeToken;

    /// @notice Base AVO emission per second (18 decimals) — before dynamic scaling
    /// @dev ~1.585 AVO/s ≈ 50M AVO/year at zero TVL
    uint256 public baseEmissionPerSecond;

    /// @notice Scale factor for dynamic emission curve (in stakeToken units, 6 decimals)
    /// @dev When totalStaked == scaleFactor, effective emission = baseEmission / 2
    uint256 public scaleFactor;

    /// @notice Last timestamp rewards were distributed
    uint256 public lastRewardTime;

    /// @notice Accumulated AVO per staked avUSDC share (scaled by 1e18 for precision)
    uint256 public accRewardPerShare;

    /// @notice Total avUSDC currently staked
    uint256 public totalStaked;

    /// @notice Total AVO minted by this contract across all time
    uint256 public totalRewardsMinted;

    /// @notice Per-user staking info
    mapping(address => UserInfo) public userInfo;

    // ─── Events ────────────────────────────────────────────────────────────────

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 reward);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event EmissionUpdated(uint256 newBaseEmission, uint256 newScaleFactor);

    // ─── Errors ────────────────────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientStake();
    error ZeroAddress();

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @param _avoToken   Address of the AVO ERC-20 token
    /// @param _stakeToken Address of avUSDC (vault share) token
    /// @param _owner      Owner address
    /// @param _baseEmissionPerSecond  Initial base emission rate (18 decimals)
    /// @param _scaleFactor            Dynamic scaling factor (6 decimals, e.g. 1_000_000e6 = $1M)
    constructor(
        address _avoToken,
        address _stakeToken,
        address _owner,
        uint256 _baseEmissionPerSecond,
        uint256 _scaleFactor
    ) Ownable(_owner) {
        if (_avoToken == address(0) || _stakeToken == address(0)) revert ZeroAddress();
        avoToken = IAVOToken(_avoToken);
        stakeToken = IERC20(_stakeToken);
        baseEmissionPerSecond = _baseEmissionPerSecond;
        scaleFactor = _scaleFactor;
        lastRewardTime = block.timestamp;
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Current effective emission rate per second, accounting for TVL scaling
    function effectiveEmissionPerSecond() public view returns (uint256) {
        if (totalStaked == 0) return baseEmissionPerSecond;
        // effectiveRate = base × scale / (totalStaked + scale)
        return (baseEmissionPerSecond * scaleFactor) / (totalStaked + scaleFactor);
    }

    /// @notice Pending AVO rewards for a user
    /// @param _user Address to check
    function pendingRewards(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 _accRewardPerShare = accRewardPerShare;

        if (block.timestamp > lastRewardTime && totalStaked > 0) {
            uint256 elapsed = block.timestamp - lastRewardTime;
            uint256 rate = effectiveEmissionPerSecond();
            uint256 reward = elapsed * rate;
            _accRewardPerShare += (reward * 1e18) / totalStaked;
        }

        return (user.amount * _accRewardPerShare / 1e18) - user.rewardDebt;
    }

    /// @notice Estimated APY for AVO emissions (basis points × 100 for precision)
    /// @dev Returns 0 if totalStaked is 0; assumes AVO has a notional price
    ///      This is a simplified view — real APY depends on AVO market price
    function emissionAPYBps() external view returns (uint256) {
        if (totalStaked == 0) return 0;
        // Annual emission in AVO tokens (18 dec) for entire pool
        uint256 annualEmission = effectiveEmissionPerSecond() * 365 days;
        // Convert totalStaked from 6 decimals to 18 for comparison
        // Assume 1 AVO ≈ $0.10 for display purposes (can be updated via oracle)
        // APY = (annualEmission × avoPrice) / (totalStaked × sharePrice) × 10000
        // Simplified: return raw emission/staked ratio in bps (frontend applies price)
        return (annualEmission * 10_000) / (uint256(totalStaked) * 1e12);
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Update reward accounting to current block
    function updatePool() public {
        if (block.timestamp <= lastRewardTime) return;

        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastRewardTime;
        uint256 rate = effectiveEmissionPerSecond();
        uint256 reward = elapsed * rate;

        // Mint AVO rewards
        avoToken.mint(address(this), reward);
        totalRewardsMinted += reward;

        accRewardPerShare += (reward * 1e18) / totalStaked;
        lastRewardTime = block.timestamp;
    }

    /// @notice Deposit avUSDC shares to start earning AVO
    /// @param amount Amount of avUSDC to stake
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        updatePool();

        UserInfo storage user = userInfo[msg.sender];

        // Claim pending rewards if already staking
        if (user.amount > 0) {
            uint256 pending = (user.amount * accRewardPerShare / 1e18) - user.rewardDebt;
            if (pending > 0) {
                _safeRewardTransfer(msg.sender, pending);
                emit Claim(msg.sender, pending);
            }
        }

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);

        user.amount += amount;
        totalStaked += amount;
        user.rewardDebt = user.amount * accRewardPerShare / 1e18;

        emit Deposit(msg.sender, amount);
    }

    /// @notice Withdraw staked avUSDC and claim pending AVO rewards
    /// @param amount Amount of avUSDC to withdraw
    function withdraw(uint256 amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (user.amount < amount) revert InsufficientStake();

        updatePool();

        uint256 pending = (user.amount * accRewardPerShare / 1e18) - user.rewardDebt;
        if (pending > 0) {
            _safeRewardTransfer(msg.sender, pending);
            emit Claim(msg.sender, pending);
        }

        user.amount -= amount;
        totalStaked -= amount;
        user.rewardDebt = user.amount * accRewardPerShare / 1e18;

        stakeToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    /// @notice Claim all pending AVO rewards without withdrawing stake
    function claim() external nonReentrant {
        updatePool();

        UserInfo storage user = userInfo[msg.sender];
        uint256 pending = (user.amount * accRewardPerShare / 1e18) - user.rewardDebt;

        if (pending > 0) {
            _safeRewardTransfer(msg.sender, pending);
            user.rewardDebt = user.amount * accRewardPerShare / 1e18;
            emit Claim(msg.sender, pending);
        }
    }

    /// @notice Emergency withdraw without claiming rewards (forfeits pending AVO)
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        if (amount == 0) revert ZeroAmount();

        totalStaked -= amount;
        user.amount = 0;
        user.rewardDebt = 0;

        stakeToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Update emission parameters. Settles outstanding rewards first.
    /// @param _baseEmissionPerSecond New base emission rate
    /// @param _scaleFactor New scale factor for dynamic curve
    function setEmissionParams(
        uint256 _baseEmissionPerSecond,
        uint256 _scaleFactor
    ) external onlyOwner {
        updatePool(); // settle at old rate first
        baseEmissionPerSecond = _baseEmissionPerSecond;
        scaleFactor = _scaleFactor;
        emit EmissionUpdated(_baseEmissionPerSecond, _scaleFactor);
    }

    /// @notice Pause deposits (withdrawals always available)
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause deposits
    function unpause() external onlyOwner { _unpause(); }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Safe transfer that caps at available balance
    function _safeRewardTransfer(address to, uint256 amount) internal {
        uint256 bal = IERC20(address(avoToken)).balanceOf(address(this));
        if (amount > bal) amount = bal;
        IERC20(address(avoToken)).transfer(to, amount);
    }
}
