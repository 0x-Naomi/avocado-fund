// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title AVOToken
/// @author Avocado Labs
/// @notice ERC-20 reward token for Avocado Fund liquidity providers.
///         Minting is restricted to an owner-settable `minter` address (initially
///         set to the owner, later typically transferred to the TokenVesting
///         contract or retained by the owner multisig). A hard supply cap is
///         enforced at 1 billion AVO.
contract AVOToken is ERC20, Ownable2Step {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum total supply: 1 billion AVO (18 decimals)
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Address authorised to mint. Initialised to the deploying owner
    ///         and changeable via `setMinter` (onlyOwner).
    address public minter;

    // ─── Events ────────────────────────────────────────────────────────────────

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    // ─── Errors ────────────────────────────────────────────────────────────────

    error OnlyMinter();
    error ExceedsMaxSupply();
    error ZeroAddress();

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyMinter() {
        if (msg.sender != minter) revert OnlyMinter();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @param _owner Initial owner (deployer / multisig). Also set as the
    ///               initial minter so the owner can bootstrap distribution
    ///               or transfer the minting role to another contract later.
    constructor(address _owner) ERC20("Avocado Token", "AVO") Ownable(_owner) {
        if (_owner == address(0)) revert ZeroAddress();
        minter = _owner;
        emit MinterUpdated(address(0), _owner);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Update the minter address. Only the contract owner can call this.
    /// @param newMinter Address of the new minter (e.g. TokenVesting, multisig)
    function setMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) revert ZeroAddress();
        address oldMinter = minter;
        minter = newMinter;
        emit MinterUpdated(oldMinter, newMinter);
    }

    // ─── Minting ───────────────────────────────────────────────────────────────

    /// @notice Mint AVO tokens. Only callable by the designated minter.
    /// @param to Recipient address
    /// @param amount Amount to mint (18 decimals)
    function mint(address to, uint256 amount) external onlyMinter {
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        _mint(to, amount);
    }
}
