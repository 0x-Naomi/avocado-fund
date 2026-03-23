// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title AVOToken
/// @author Avocado Labs
/// @notice ERC-20 reward token for Avocado Fund liquidity providers.
///         Minting is restricted to the owner (VaultRewards contract)
///         and a hard supply cap is enforced.
contract AVOToken is ERC20, Ownable2Step {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum total supply: 100 million AVO (18 decimals)
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Address authorised to mint (set to VaultRewards after deployment)
    address public minter;

    // ─── Events ────────────────────────────────────────────────────────────────

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    // ─── Errors ────────────────────────────────────────────────────────────────

    error OnlyMinter();
    error ExceedsMaxSupply();
    error ZeroAddress();

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @param _owner Initial owner (deployer / multisig)
    constructor(address _owner) ERC20("Avocado Token", "AVO") Ownable(_owner) {}

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Set the minter address. Only the contract owner can call this.
    /// @param _minter Address of the VaultRewards contract
    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert ZeroAddress();
        emit MinterUpdated(minter, _minter);
        minter = _minter;
    }

    // ─── Minting ───────────────────────────────────────────────────────────────

    /// @notice Mint AVO tokens. Only callable by the designated minter.
    /// @param to Recipient address
    /// @param amount Amount to mint (18 decimals)
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        _mint(to, amount);
    }
}
