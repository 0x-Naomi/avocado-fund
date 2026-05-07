// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAVOToken
/// @notice Minimal interface for the AVO reward token.
/// @dev Consumed by any contract that needs to mint AVO (e.g. TokenVesting).
interface IAVOToken {
    /// @notice Mint AVO tokens
    /// @param to Recipient
    /// @param amount Amount to mint (18 decimals)
    function mint(address to, uint256 amount) external;

    /// @notice Maximum token supply cap
    function MAX_SUPPLY() external view returns (uint256);

    /// @notice Current total supply
    function totalSupply() external view returns (uint256);
}
