// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAvocadoLending
/// @notice Interface for the Avocado Fund lending/borrowing contract
interface IAvocadoLending {
    // ─── Structs ──────────────────────────────────────────────────────────────

    struct Borrower {
        uint256 creditLimit;       // Max USDC this borrower can borrow
        uint256 principal;         // Current outstanding principal
        uint256 interestIndex;     // Borrower's interest index snapshot
        uint64  lastInterestTime;  // Last timestamp interest was accrued
        bool    isApproved;        // Whether borrower is whitelisted
        bool    isDefaulted;       // Whether borrower has defaulted
    }

    struct LoanTerms {
        uint256 amount;
        uint256 interestRateBps;   // Annual rate in basis points
        uint256 dueDate;
        bool    repaid;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event BorrowerApproved(address indexed borrower, uint256 creditLimit);
    event BorrowerRevoked(address indexed borrower);
    event CreditLimitUpdated(address indexed borrower, uint256 oldLimit, uint256 newLimit);
    event LoanOriginated(address indexed borrower, uint256 loanId, uint256 amount, uint256 rate);
    event LoanRepaid(address indexed borrower, uint256 loanId, uint256 principal, uint256 interest);
    event BorrowerDefaulted(address indexed borrower, uint256 outstandingDebt);
    event InterestRateUpdated(uint256 oldRate, uint256 newRate);
    event InterestAccrued(uint256 totalInterest);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error BorrowerNotApproved(address borrower);
    error ExceedsCreditLimit(uint256 requested, uint256 available);
    error InsufficientVaultLiquidity(uint256 available, uint256 requested);
    error ZeroAmount();
    error ZeroAddress();
    error AlreadyApproved(address borrower);
    error LoanNotFound(uint256 loanId);
    error LoanAlreadyRepaid(uint256 loanId);
    error NotBorrower(address caller, address borrower);
    error InvalidRate(uint256 rate);

    // ─── View functions ───────────────────────────────────────────────────────

    /// @notice Get borrower data
    function getBorrower(address borrower) external view returns (Borrower memory);

    /// @notice Get a specific loan
    function getLoan(address borrower, uint256 loanId) external view returns (LoanTerms memory);

    /// @notice Total outstanding debt (principal + accrued interest)
    function totalOutstandingDebt() external view returns (uint256);

    /// @notice Outstanding debt for a specific borrower
    function borrowerDebt(address borrower) external view returns (uint256 principal, uint256 interest);

    /// @notice Current borrow interest rate in basis points per year
    function borrowRateBps() external view returns (uint256);

    /// @notice The vault contract that supplies capital
    function vault() external view returns (address);

    /// @notice Total capital deployed from vault
    function totalDeployed() external view returns (uint256);

    // ─── Borrower functions ───────────────────────────────────────────────────

    /// @notice Borrow USDC against credit limit
    function borrow(uint256 amount) external returns (uint256 loanId);

    /// @notice Repay a loan (full or partial)
    function repay(uint256 loanId, uint256 amount) external;

    /// @notice Repay all outstanding debt for caller
    function repayAll() external;

    // ─── Admin functions ──────────────────────────────────────────────────────

    /// @notice Approve a borrower with a credit limit
    function approveBorrower(address borrower, uint256 creditLimit) external;

    /// @notice Revoke a borrower's access
    function revokeBorrower(address borrower) external;

    /// @notice Update a borrower's credit limit
    function setCreditLimit(address borrower, uint256 newLimit) external;

    /// @notice Update the base borrow rate
    function setBorrowRate(uint256 newRateBps) external;

    /// @notice Mark a borrower as defaulted
    function declareDefault(address borrower) external;

    /// @notice Return all available funds to vault
    function returnFundsToVault(uint256 amount) external;

    /// @notice Accrue interest across all active borrowers
    function accrueAllInterest() external returns (uint256 totalInterest);
}
