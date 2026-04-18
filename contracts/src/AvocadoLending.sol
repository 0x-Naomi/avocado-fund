// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAvocadoLending} from "./interfaces/IAvocadoLending.sol";
import {AvocadoVault} from "./AvocadoVault.sol";

/// @title AvocadoLending
/// @author Avocado Labs
/// @notice Credit-based lending contract. Approved borrowers receive USDC from the
///         AvocadoVault against on-chain identity / credit limits set by governance.
///         Interest accrues per-second using a simple interest model. When repayments
///         are made, interest is reported back to the vault so share price increases.
///
/// @dev Key design decisions:
///      - Borrowers are whitelisted by owner (governance / credit committee)
///      - Each borrower has a credit limit and can have multiple outstanding loans
///      - Interest is accrued continuously using block.timestamp
///      - Borrow rate is set globally (can be updated by governance)
///      - On repay, interest portion is reported to vault via reportInterest()
///      - Borrower defaults are recorded on-chain for credit history
///      - All USDC amounts use 6 decimals (native USDC precision)
contract AvocadoLending is IAvocadoLending, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant SECONDS_PER_YEAR  = 365 days;
    uint256 public constant BPS_DENOMINATOR    = 10_000;
    uint256 public constant MAX_BORROW_RATE_BPS = 5_000; // 50% max APR
    uint256 public constant PRECISION          = 1e18;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @inheritdoc IAvocadoLending
    address public immutable vault;

    /// @notice The USDC token
    IERC20 public immutable usdc;

    /// @inheritdoc IAvocadoLending
    uint256 public borrowRateBps;

    /// @inheritdoc IAvocadoLending
    uint256 public totalDeployed;

    /// @notice Total outstanding principal across all borrowers
    uint256 public totalPrincipal;

    /// @notice Accumulated interest not yet reported to vault
    uint256 public pendingInterest;

    /// @notice Borrower metadata
    mapping(address => Borrower) private _borrowers;

    /// @notice Loan records per borrower
    mapping(address => LoanTerms[]) private _loans;

    /// @notice All approved borrower addresses (for iteration)
    address[] public borrowerList;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _vault        Address of the AvocadoVault
    /// @param _usdc         Address of USDC token
    /// @param _owner        Owner (governance / multisig)
    /// @param _borrowRateBps Initial annual borrow rate in basis points
    constructor(
        address _vault,
        address _usdc,
        address _owner,
        uint256 _borrowRateBps
    ) Ownable(_owner) {
        if (_vault == address(0) || _usdc == address(0)) revert ZeroAddress();
        if (_borrowRateBps > MAX_BORROW_RATE_BPS) revert InvalidRate(_borrowRateBps);

        vault = _vault;
        usdc = IERC20(_usdc);
        borrowRateBps = _borrowRateBps;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyApprovedBorrower() {
        if (!_borrowers[msg.sender].isApproved) revert BorrowerNotApproved(msg.sender);
        _;
    }

    // ─── Borrower functions ───────────────────────────────────────────────────

    /// @inheritdoc IAvocadoLending
    /// @dev Pulls USDC from the vault to this contract, then forwards to borrower.
    ///      Borrower must have sufficient credit headroom.
    function borrow(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyApprovedBorrower
        returns (uint256 loanId)
    {
        if (amount == 0) revert ZeroAmount();

        Borrower storage b = _borrowers[msg.sender];
        if (b.isDefaulted) revert BorrowerNotApproved(msg.sender);

        // Check credit headroom — include accrued interest so total exposure
        // (principal + interest + new borrow) never exceeds the credit limit.
        uint256 currentPrincipal = _currentPrincipal(msg.sender);
        uint256 accruedInterest = _pendingBorrowerInterest(msg.sender);
        uint256 currentDebt = currentPrincipal + accruedInterest;
        if (currentDebt + amount > b.creditLimit) {
            revert ExceedsCreditLimit(amount, b.creditLimit > currentDebt ? b.creditLimit - currentDebt : 0);
        }

        // Check vault has enough idle liquidity
        uint256 vaultIdle = usdc.balanceOf(vault);
        uint256 vaultDeployed = AvocadoVault(vault).deployedAssets();
        // We hold the funds already deployed here; just check what vault can give us
        uint256 available = vaultDeployed == 0 ? vaultIdle : usdc.balanceOf(address(this));
        if (amount > usdc.balanceOf(address(this))) {
            // Need more from vault - vault owner must have called deployToLending first
            revert InsufficientVaultLiquidity(usdc.balanceOf(address(this)), amount);
        }

        // Accrue existing interest before new borrow
        _accrueInterest(msg.sender);

        // Record loan
        loanId = _loans[msg.sender].length;
        _loans[msg.sender].push(LoanTerms({
            amount: amount,
            interestRateBps: borrowRateBps,
            dueDate: block.timestamp + 30 days, // 30 day default term
            repaid: false
        }));

        b.principal += amount;
        b.lastInterestTime = uint64(block.timestamp);
        totalPrincipal += amount;

        // Transfer USDC to borrower
        usdc.safeTransfer(msg.sender, amount);

        emit LoanOriginated(msg.sender, loanId, amount, borrowRateBps);
    }

    /// @inheritdoc IAvocadoLending
    function repay(uint256 loanId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        LoanTerms storage loan = _loans[msg.sender][loanId];
        if (loan.amount == 0) revert LoanNotFound(loanId);
        if (loan.repaid) revert LoanAlreadyRepaid(loanId);

        // Accrue interest first
        uint256 interestOwed = _accrueInterest(msg.sender);

        Borrower storage b = _borrowers[msg.sender];

        // Apply payment: first to interest, then to principal
        uint256 remaining = amount;
        uint256 interestPayment = 0;
        uint256 principalPayment = 0;

        if (remaining >= interestOwed) {
            interestPayment = interestOwed;
            remaining -= interestOwed;
            pendingInterest += interestPayment;
        } else {
            interestPayment = remaining;
            pendingInterest += interestPayment;
            remaining = 0;
        }

        if (remaining > 0) {
            principalPayment = remaining < b.principal ? remaining : b.principal;
            b.principal -= principalPayment;
            if (b.principal == 0) loan.repaid = true;
        }

        // Cap total amount to actual debt
        uint256 actualAmount = interestPayment + principalPayment;
        totalPrincipal = totalPrincipal > principalPayment ? totalPrincipal - principalPayment : 0;

        // Pull USDC from repayer
        usdc.safeTransferFrom(msg.sender, address(this), actualAmount);

        // Report interest to vault (increases share price)
        if (interestPayment > 0) {
            _reportInterestToVault(interestPayment);
        }

        emit LoanRepaid(msg.sender, loanId, principalPayment, interestPayment);
    }

    /// @inheritdoc IAvocadoLending
    function repayAll() external nonReentrant {
        Borrower storage b = _borrowers[msg.sender];
        if (b.principal == 0) return;

        uint256 interestOwed = _accrueInterest(msg.sender);
        uint256 totalOwed = b.principal + interestOwed;

        uint256 principal = b.principal;
        b.principal = 0;
        totalPrincipal = totalPrincipal > principal ? totalPrincipal - principal : 0;

        // Mark all loans repaid
        LoanTerms[] storage loans = _loans[msg.sender];
        for (uint256 i = 0; i < loans.length; i++) {
            if (!loans[i].repaid) {
                loans[i].repaid = true;
            }
        }

        pendingInterest += interestOwed;

        // Pull full debt from borrower
        usdc.safeTransferFrom(msg.sender, address(this), totalOwed);

        // Report interest to vault
        if (interestOwed > 0) {
            _reportInterestToVault(interestOwed);
        }

        emit RepaidAll(msg.sender, principal, interestOwed);
    }

    // ─── Admin functions ──────────────────────────────────────────────────────

    /// @inheritdoc IAvocadoLending
    function approveBorrower(address borrower, uint256 creditLimit, uint256 worldIdNullifier)
        external
        onlyOwner
    {
        if (borrower == address(0)) revert ZeroAddress();
        if (creditLimit == 0) revert ZeroAmount();

        Borrower storage b = _borrowers[borrower];
        if (!b.isApproved) {
            borrowerList.push(borrower);
        }

        b.isApproved = true;
        b.creditLimit = creditLimit;
        b.worldIdNullifier = worldIdNullifier;
        b.lastInterestTime = uint64(block.timestamp);

        emit BorrowerApproved(borrower, creditLimit);
    }

    /// @inheritdoc IAvocadoLending
    function revokeBorrower(address borrower) external onlyOwner {
        _borrowers[borrower].isApproved = false;
        emit BorrowerRevoked(borrower);
    }

    /// @inheritdoc IAvocadoLending
    function markDefault(address borrower) external onlyOwner {
        Borrower storage b = _borrowers[borrower];
        if (b.principal == 0) revert ZeroAmount();

        uint256 interestOwed = _pendingBorrowerInterest(borrower);
        uint256 totalLost = b.principal + interestOwed;

        b.isDefaulted = true;
        b.isApproved = false;
        totalPrincipal = totalPrincipal > b.principal ? totalPrincipal - b.principal : 0;
        b.principal = 0;

        emit BorrowerDefaulted(borrower, totalLost);
    }

    /// @inheritdoc IAvocadoLending
    function setBorrowRate(uint256 newRateBps) external onlyOwner {
        if (newRateBps > MAX_BORROW_RATE_BPS) revert InvalidRate(newRateBps);
        uint256 old = borrowRateBps;
        borrowRateBps = newRateBps;
        emit BorrowRateUpdated(old, newRateBps);
    }

    /// @inheritdoc IAvocadoLending
    function receiveFromVault(uint256 amount) external {
        if (msg.sender != vault) revert Unauthorized(msg.sender);
        totalDeployed += amount;
        // USDC already transferred by vault via safeTransfer before calling this
        emit FundsReceived(amount);
    }

    /// @inheritdoc IAvocadoLending
    function returnToVault(uint256 amount) external onlyOwner {
        if (amount > usdc.balanceOf(address(this))) revert InsufficientVaultLiquidity(usdc.balanceOf(address(this)), amount);
        totalDeployed = totalDeployed > amount ? totalDeployed - amount : 0;
        usdc.safeTransfer(vault, amount);
        emit FundsReturned(amount);
    }

    /// @notice Pause the contract (emergency stop)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /// @inheritdoc IAvocadoLending
    function getBorrower(address borrower) external view returns (Borrower memory) {
        return _borrowers[borrower];
    }

    /// @inheritdoc IAvocadoLending
    function getLoan(address borrower, uint256 loanId) external view returns (LoanTerms memory) {
        return _loans[borrower][loanId];
    }

    /// @inheritdoc IAvocadoLending
    function getLoanCount(address borrower) external view returns (uint256) {
        return _loans[borrower].length;
    }

    /// @inheritdoc IAvocadoLending
    function getTotalDebt(address borrower) external view returns (uint256 principal, uint256 interest) {
        principal = _borrowers[borrower].principal;
        interest = _pendingBorrowerInterest(borrower);
    }

    /// @inheritdoc IAvocadoLending
    function getAvailableCredit(address borrower) external view returns (uint256) {
        Borrower storage b = _borrowers[borrower];
        if (!b.isApproved || b.isDefaulted) return 0;
        uint256 currentDebt = _currentPrincipal(borrower) + _pendingBorrowerInterest(borrower);
        return b.creditLimit > currentDebt ? b.creditLimit - currentDebt : 0;
    }

    // ─── Internal functions ───────────────────────────────────────────────────

    /// @notice Returns the current principal for a borrower
    function _currentPrincipal(address borrower) internal view returns (uint256) {
        return _borrowers[borrower].principal;
    }

    /// @notice Calculate pending interest for a borrower (not yet accrued)
    function _pendingBorrowerInterest(address borrower) internal view returns (uint256) {
        Borrower storage b = _borrowers[borrower];
        if (b.principal == 0 || b.lastInterestTime == 0) return 0;

        uint256 elapsed = block.timestamp - b.lastInterestTime;
        // Simple interest: principal * rate * time / (SECONDS_PER_YEAR * BPS_DENOMINATOR)
        return (b.principal * borrowRateBps * elapsed) / (SECONDS_PER_YEAR * BPS_DENOMINATOR);
    }

    /// @notice Accrue interest for a borrower and update state
    /// @return interestAccrued The amount of interest accrued
    function _accrueInterest(address borrower) internal returns (uint256 interestAccrued) {
        interestAccrued = _pendingBorrowerInterest(borrower);
        _borrowers[borrower].lastInterestTime = uint64(block.timestamp);
        // Note: accrued interest is tracked separately; added to pendingInterest on repayment
    }

    /// @notice Report interest to the vault to increase share price
    function _reportInterestToVault(uint256 interestAmount) internal {
        pendingInterest = pendingInterest > interestAmount ? pendingInterest - interestAmount : 0;
        AvocadoVault(vault).reportInterest(interestAmount);
    }
}