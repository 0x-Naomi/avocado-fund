// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TokenVesting
/// @author Avocado Labs
/// @notice Linear token vesting with cliff for team and advisor allocations.
///         Owner creates vesting schedules; beneficiaries claim unlocked tokens over time.
///
/// @dev Schedule: 0% at TGE → cliff period → linear monthly vest → fully vested.
///      - Founders:  12-month cliff, 24-month linear vest (36 months total)
///      - Advisors:   6-month cliff, 18-month linear vest (24 months total)
contract TokenVesting is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Structs ───────────────────────────────────────────────────────────────

    struct Schedule {
        address beneficiary;     // recipient
        uint256 totalAmount;     // total tokens to vest
        uint256 released;        // tokens already claimed
        uint256 start;           // vesting start timestamp (TGE)
        uint256 cliffDuration;   // duration before any tokens unlock (seconds)
        uint256 vestDuration;    // duration of linear vest after cliff (seconds)
        bool    revocable;       // whether owner can revoke unvested tokens
        bool    revoked;         // has been revoked
    }

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice The token being vested (AVO)
    IERC20 public immutable token;

    /// @notice All vesting schedules
    Schedule[] public schedules;

    /// @notice Schedule IDs for each beneficiary
    mapping(address => uint256[]) public beneficiarySchedules;

    /// @notice Total tokens reserved across all active schedules
    uint256 public totalReserved;

    // ─── Events ────────────────────────────────────────────────────────────────

    event ScheduleCreated(uint256 indexed scheduleId, address indexed beneficiary, uint256 totalAmount);
    event TokensReleased(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(uint256 indexed scheduleId, address indexed beneficiary, uint256 unvested);

    // ─── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error InvalidDuration();
    error InsufficientBalance();
    error NotRevocable();
    error AlreadyRevoked();
    error NothingToRelease();
    error InvalidSchedule();

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @param _token   AVO token address
    /// @param _owner   Multisig / deployer that creates schedules
    constructor(address _token, address _owner) Ownable(_owner) {
        if (_token == address(0)) revert ZeroAddress();
        token = IERC20(_token);
    }

    // ─── Admin: Create Schedule ────────────────────────────────────────────────

    /// @notice Create a new vesting schedule. Tokens must already be deposited in this contract.
    /// @param _beneficiary   Recipient address
    /// @param _totalAmount   Total tokens to vest (18 decimals)
    /// @param _start         Vesting start timestamp (usually TGE)
    /// @param _cliffDuration Cliff duration in seconds (e.g. 365 days for 12-month cliff)
    /// @param _vestDuration  Linear vest duration in seconds after cliff (e.g. 730 days for 24 months)
    /// @param _revocable     Whether the owner can revoke unvested tokens
    function createSchedule(
        address _beneficiary,
        uint256 _totalAmount,
        uint256 _start,
        uint256 _cliffDuration,
        uint256 _vestDuration,
        bool _revocable
    ) external onlyOwner {
        if (_beneficiary == address(0)) revert ZeroAddress();
        if (_totalAmount == 0) revert ZeroAmount();
        if (_vestDuration == 0) revert InvalidDuration();

        // Ensure contract has enough tokens
        uint256 available = token.balanceOf(address(this)) - totalReserved;
        if (available < _totalAmount) revert InsufficientBalance();

        uint256 scheduleId = schedules.length;

        schedules.push(Schedule({
            beneficiary: _beneficiary,
            totalAmount: _totalAmount,
            released: 0,
            start: _start,
            cliffDuration: _cliffDuration,
            vestDuration: _vestDuration,
            revocable: _revocable,
            revoked: false
        }));

        beneficiarySchedules[_beneficiary].push(scheduleId);
        totalReserved += _totalAmount;

        emit ScheduleCreated(scheduleId, _beneficiary, _totalAmount);
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Total number of vesting schedules
    function scheduleCount() external view returns (uint256) {
        return schedules.length;
    }

    /// @notice Get all schedule IDs for a beneficiary
    function getScheduleIds(address _beneficiary) external view returns (uint256[] memory) {
        return beneficiarySchedules[_beneficiary];
    }

    /// @notice Tokens vested (unlocked) for a schedule at the given timestamp
    /// @param _scheduleId Schedule index
    /// @param _timestamp  Timestamp to check (use block.timestamp for current)
    function vestedAmount(uint256 _scheduleId, uint256 _timestamp) public view returns (uint256) {
        if (_scheduleId >= schedules.length) revert InvalidSchedule();
        Schedule storage s = schedules[_scheduleId];

        if (s.revoked) {
            return s.released; // only what was already released
        }

        return _computeVested(s, _timestamp);
    }

    /// @notice Tokens currently claimable (vested minus already released)
    /// @param _scheduleId Schedule index
    function releasable(uint256 _scheduleId) public view returns (uint256) {
        if (_scheduleId >= schedules.length) revert InvalidSchedule();
        Schedule storage s = schedules[_scheduleId];
        return vestedAmount(_scheduleId, block.timestamp) - s.released;
    }

    /// @notice Total releasable across all schedules for a beneficiary
    function totalReleasable(address _beneficiary) external view returns (uint256 total) {
        uint256[] storage ids = beneficiarySchedules[_beneficiary];
        for (uint256 i = 0; i < ids.length; i++) {
            total += releasable(ids[i]);
        }
    }

    // ─── Claim ─────────────────────────────────────────────────────────────────

    /// @notice Release vested tokens for a specific schedule
    /// @param _scheduleId Schedule index
    function release(uint256 _scheduleId) external nonReentrant {
        if (_scheduleId >= schedules.length) revert InvalidSchedule();
        Schedule storage s = schedules[_scheduleId];

        uint256 amount = releasable(_scheduleId);
        if (amount == 0) revert NothingToRelease();

        s.released += amount;
        totalReserved -= amount;
        token.safeTransfer(s.beneficiary, amount);

        emit TokensReleased(_scheduleId, s.beneficiary, amount);
    }

    /// @notice Release all vested tokens across all schedules for the caller
    function releaseAll() external nonReentrant {
        uint256[] storage ids = beneficiarySchedules[msg.sender];
        uint256 totalAmount = 0;

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 amount = releasable(ids[i]);
            if (amount > 0) {
                schedules[ids[i]].released += amount;
                totalAmount += amount;
                emit TokensReleased(ids[i], msg.sender, amount);
            }
        }

        if (totalAmount == 0) revert NothingToRelease();
        totalReserved -= totalAmount;
        token.safeTransfer(msg.sender, totalAmount);
    }

    // ─── Admin: Revoke ─────────────────────────────────────────────────────────

    /// @notice Revoke a vesting schedule. Releases vested tokens to beneficiary,
    ///         returns unvested tokens to owner.
    /// @param _scheduleId Schedule index
    function revoke(uint256 _scheduleId) external onlyOwner nonReentrant {
        if (_scheduleId >= schedules.length) revert InvalidSchedule();
        Schedule storage s = schedules[_scheduleId];
        if (!s.revocable) revert NotRevocable();
        if (s.revoked) revert AlreadyRevoked();

        // Release any vested but unclaimed tokens to beneficiary
        uint256 vested = _computeVested(s, block.timestamp);
        uint256 unreleased = vested - s.released;
        if (unreleased > 0) {
            s.released += unreleased;
            token.safeTransfer(s.beneficiary, unreleased);
            emit TokensReleased(_scheduleId, s.beneficiary, unreleased);
        }

        // Return unvested tokens to owner
        uint256 unvested = s.totalAmount - vested;
        s.revoked = true;
        totalReserved -= unvested;

        if (unvested > 0) {
            token.safeTransfer(owner(), unvested);
        }

        emit ScheduleRevoked(_scheduleId, s.beneficiary, unvested);
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Compute vested amount based on linear schedule with cliff
    function _computeVested(Schedule storage s, uint256 _timestamp) internal view returns (uint256) {
        // Before cliff: nothing vested
        if (_timestamp < s.start + s.cliffDuration) {
            return 0;
        }

        // After full vest: everything vested
        uint256 vestEnd = s.start + s.cliffDuration + s.vestDuration;
        if (_timestamp >= vestEnd) {
            return s.totalAmount;
        }

        // During linear vest: proportional
        uint256 elapsed = _timestamp - (s.start + s.cliffDuration);
        return (s.totalAmount * elapsed) / s.vestDuration;
    }
}
