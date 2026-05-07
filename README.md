<p align="center">
  <img src="https://avocado.fund/logos/avocado-fund-logo.svg" alt="avocado.fund" height="40" />
</p>

<p align="center">
  Uncollateralised USDC lending on Arbitrum.<br/>
  Real yield from borrower interest. Identity-verified credit via Persona KYC.
</p>

<p align="center">
  <a href="https://avocado.fund">avocado.fund</a>
  &nbsp;·&nbsp;
  <a href="https://arbiscan.io/address/0xa3185e9ad376bc95600b65648bac02af23653741">Vault on Arbiscan</a>
  &nbsp;·&nbsp;
  <a href="https://arbiscan.io/address/0xff27baee76495a33caed3c7cad31e404034b8911">Lending on Arbiscan</a>
</p>

<p align="center">
  <img alt="Solidity" src="https://img.shields.io/badge/Solidity-0.8.28-363636?logo=solidity&logoColor=white" />
  <img alt="Chain" src="https://img.shields.io/badge/Chain-Arbitrum%20One-28A0F0?logo=ethereum&logoColor=white" />
  <img alt="Framework" src="https://img.shields.io/badge/Framework-Foundry-EF4444" />
  <img alt="License" src="https://img.shields.io/badge/License-MIT-22C55E" />
  <img alt="Audit" src="https://img.shields.io/badge/Audit-Omniscia-6366F1" />
</p>

## What is Avocado Fund?

Avocado Fund is a decentralised USDC lending protocol on Arbitrum. Lenders deposit USDC to earn yield from real loan interest. Borrowers verify their identity with Persona KYC, receive an on-chain AVO Score, and access unsecured credit lines up to **$10,000** — no collateral required.

Traditional DeFi requires $150 locked to borrow $100. We replace collateral with identity.

## For Lenders

Deposit USDC and receive `avUSDC` — an ERC-4626 share token. As borrowers repay interest, the vault's share price rises automatically. No lockup, withdraw any time.

| Property | Value |
|---|---|
| Base APR | 12% from borrower interest |
| Vault standard | ERC-4626 |
| Vault cap | $4,000,000 USDC |
| Performance fee | 10% of interest |
| Idle buffer | ~10% kept for instant withdrawals |

## For Borrowers

1. Complete Persona KYC — government ID + biometric liveness check
2. Soft credit bureau check — no impact on your credit score
3. Credit committee approves your AVO Score and assigns a credit limit
4. Call `borrow()` — USDC arrives in your wallet, interest accrues per second
5. Repay on time, AVO Score rises, credit limit increases

| AVO Score | Credit Limit |
|---|---|
| 75+ | $10,000 |
| 65–74 | $1,000 |
| 50–64 | $500 |
| 30–49 | $250 |
| 10–29 | $100 |
| < 10 | $25 |

Default has real consequences: on-chain blacklist, credit bureau reporting, and 80% face-value debt recovery — making unsecured lending viable.

## AVO Score

Every borrower has a 0–100 AVO Score — Avocado Fund's on-chain credit rating. It determines credit tier and limit.

| Component | Max Points |
|---|---|
| Identity (Persona KYC) | 15 |
| Bureau score | 20 |
| Repayment history | 30 |
| Account tenure | 10 |
| Volume repaid | 10 |
| Utilisation | 10 |
| Bonus (perfect record) | 5 |

## Smart Contracts

| Contract | Description |
|---|---|
| [`AvocadoVault.sol`](contracts/src/AvocadoVault.sol) | ERC-4626 USDC vault — deposits mint `avUSDC`; `reportInterest()` raises share price; 10% performance fee |
| [`AvocadoLending.sol`](contracts/src/AvocadoLending.sol) | Credit line management — Persona KYC gate, `borrow()` / `repay()`, per-second interest, default declaration |
| [`AVOToken.sol`](contracts/src/AVOToken.sol) | ERC-20 governance token — 1B max supply |
| [`TokenVesting.sol`](contracts/src/TokenVesting.sol) | Cliff + linear vesting for team and advisor allocations |

Audited by [Omniscia](https://omniscia.io) — 19 findings, all remediated.

## Deployed Addresses

**Arbitrum One**

| Contract | Address |
|---|---|
| AvocadoVault | [`0xa3185e9AD376BC95600b65648bac02aF23653741`](https://arbiscan.io/address/0xa3185e9ad376bc95600b65648bac02af23653741) |
| AvocadoLending | [`0xFF27bAeE76495a33CAed3c7cad31E404034b8911`](https://arbiscan.io/address/0xff27baee76495a33caed3c7cad31e404034b8911) |
| USDC | [`0xaf88d065e77c8cC2239327C5EDb3A432268e5831`](https://arbiscan.io/address/0xaf88d065e77c8cc2239327c5edb3a432268e5831) |

## Build & Test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
cd contracts
forge install
forge build
forge test -vvv
```

## Security

- Audited by Omniscia — 19 findings (4 static + 15 manual), all remediated
- `Ownable2Step` on all admin contracts
- OpenZeppelin v5.x (ERC4626, ReentrancyGuard, SafeERC20, Pausable)

## License

[MIT](https://opensource.org/licenses/MIT)
