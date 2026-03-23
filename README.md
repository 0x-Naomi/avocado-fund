<p align="center">
  <img src="https://raw.githubusercontent.com/0x-Naomi/avocado-fund/main/contracts/src/AvocadoVault.sol" width="0" height="0" />
  <h1 align="center">🥑 Avocado Fund</h1>
</p>

<p align="center">
  <strong>Decentralised USDC Lending Protocol on Base</strong>
</p>

<p align="center">
  <a href="https://avocado.fund">🌐 Website</a>&nbsp;&nbsp;•&nbsp;&nbsp;
  <a href="#contracts">📜 Contracts</a>&nbsp;&nbsp;•&nbsp;&nbsp;
  <a href="#architecture">🏗️ Architecture</a>&nbsp;&nbsp;•&nbsp;&nbsp;
  <a href="#build--test">🧪 Tests</a>&nbsp;&nbsp;•&nbsp;&nbsp;
  <a href="#audit">🔒 Audit</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Solidity-^0.8.28-363636?logo=solidity" alt="Solidity" />
  <img src="https://img.shields.io/badge/Framework-Foundry-orange?logo=ethereum" alt="Foundry" />
  <img src="https://img.shields.io/badge/Chain-Base-0052FF?logo=coinbase" alt="Base" />
  <img src="https://img.shields.io/badge/OpenZeppelin-v5.x-4E5EE4?logo=openzeppelin" alt="OpenZeppelin" />
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License" />
</p>

---

## Overview

Avocado Fund is a decentralised lending protocol where **lenders** deposit USDC into an ERC-4626 vault to earn yield, and **borrowers** access uncollateralised credit through [World ID](https://worldcoin.org/world-id) proof-of-personhood verification. AVO token rewards incentivise long-term liquidity provision.

---

## Contracts

| Contract | Description | LOC |
|:---------|:------------|----:|
| [**AvocadoVault.sol**](contracts/src/AvocadoVault.sol) | ERC-4626 vault — accepts USDC deposits, mints avUSDC shares, deploys capital to lending pool | ~300 |
| [**AvocadoLending.sol**](contracts/src/AvocadoLending.sol) | Credit line engine — World ID verification, borrow/repay, per-second interest accrual, sybil resistance | ~400 |
| [**AVOToken.sol**](contracts/src/AVOToken.sol) | ERC-20 governance & reward token — 100 M max supply, minter-restricted minting | ~60 |
| [**VaultRewards.sol**](contracts/src/VaultRewards.sol) | MasterChef-style staking — stake avUSDC, earn AVO with dynamic emission curve | ~240 |

### Interfaces

| Interface | Path |
|:----------|:-----|
| IAvocadoVault | [`contracts/src/interfaces/IAvocadoVault.sol`](contracts/src/interfaces/IAvocadoVault.sol) |
| IAvocadoLending | [`contracts/src/interfaces/IAvocadoLending.sol`](contracts/src/interfaces/IAvocadoLending.sol) |

---

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │            Avocado Fund              │
                    └─────────────────────────────────────┘

 Lenders                                            Borrowers
    │                                                   │
    │  USDC                                  World ID   │
    ▼                                        Verified   ▼
┌──────────────────┐    deploys capital    ┌──────────────────┐
│  AvocadoVault    │ ──────────────────►   │ AvocadoLending   │
│  (ERC-4626)      │                       │                  │
│                  │   ◄────────────────── │  borrow / repay  │
│  USDC → avUSDC   │    interest returns   │  interest accrual│
└──────────────────┘                       └──────────────────┘
         │
         │ stake avUSDC
         ▼
┌──────────────────┐
│  VaultRewards    │ ──► AVO token rewards
│  (MasterChef)    │
└──────────────────┘
         │
         ▼
┌──────────────────┐
│   AVOToken       │
│   (ERC-20)       │
│   100M supply    │
└──────────────────┘
```

---

## Build & Test

```bash
cd contracts

# Install dependencies
forge install

# Compile
forge build

# Run all tests
forge test -vvv

# Run specific test
forge test --match-contract AvocadoVaultTest -vvv
```

---

## Test Suite

| Test File | Target | Tests |
|:----------|:-------|------:|
| [`AVOToken.t.sol`](contracts/test/AVOToken.t.sol) | AVOToken | 17 |
| [`AvocadoVault.t.sol`](contracts/test/AvocadoVault.t.sol) | AvocadoVault | 21 |
| [`AvocadoLending.t.sol`](contracts/test/AvocadoLending.t.sol) | AvocadoLending | 39 |
| [`VaultRewards.t.sol`](contracts/test/VaultRewards.t.sol) | VaultRewards | 18 |
| [`Integration.t.sol`](contracts/test/Integration.t.sol) | End-to-end | — |

---

## Key Security Features

- **Ownable2Step** — Two-step ownership transfer on all admin contracts
- **ReentrancyGuard** — Non-reentrant protection on deposit/withdraw/borrow/repay
- **Pausable** — Emergency pause capability for deposits (withdrawals always available)
- **SafeERC20** — Safe token transfer wrappers
- **World ID** — Sybil-resistant borrower verification
- **Minter-restricted** — AVO minting limited to designated minter address

---

## Audit

> 🔍 **This repository is prepared for security audit.**

### Scope

All Solidity files in [`contracts/src/`](contracts/src/) are in scope:

```
contracts/src/
├── AvocadoVault.sol        (~300 LOC)
├── AvocadoLending.sol      (~400 LOC)
├── AVOToken.sol            (~60 LOC)
├── VaultRewards.sol        (~240 LOC)
└── interfaces/
    ├── IAvocadoVault.sol
    └── IAvocadoLending.sol
```

**Total LOC in scope: ~1,000**

### Known Risks

- Uncollateralised lending — borrower defaults reduce lender share value
- Dynamic emission curve — integer division may cause dust loss in reward calculations
- External dependency on World ID verifier contract

---

## Dependencies

| Dependency | Version | Purpose |
|:-----------|:--------|:--------|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | v5.x | ERC4626, ERC20, Access Control, Security |
| [Forge Std](https://github.com/foundry-rs/forge-std) | latest | Testing framework |

---

## Deployment

| Network | Chain ID | Status |
|:--------|:---------|:-------|
| Base | 8453 | 🟢 Production |
| Base Sepolia | 84532 | 🟢 Testnet |

---

<p align="center">
  <sub>Built with 🥑 by the Avocado Fund team</sub>
</p>
