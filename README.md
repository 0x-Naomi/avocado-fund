<p align="center">
  <img src="https://avocado.fund/logos/avocado-fund-logo.svg" alt="Avocado Fund" height="48" />
</p>

<h3 align="center">Uncollateralised USDC Lending on Arbitrum</h3>

<p align="center">
  Borrow without locking up crypto. Lend and earn real yield. Build your on-chain credit history.
</p>

<p align="center">
  <a href="https://avocado.fund"><strong>avocado.fund</strong></a>
  &nbsp;·&nbsp;
  <a href="https://x.com/_avocadofund">@_avocadofund</a>
  &nbsp;·&nbsp;
  <a href="https://t.me/avocadofund">Telegram</a>
</p>

<p align="center">
  <img alt="Chain" src="https://img.shields.io/badge/Arbitrum%20One-28A0F0?logo=ethereum&logoColor=white" />
  <img alt="Solidity" src="https://img.shields.io/badge/Solidity-0.8.28-363636?logo=solidity&logoColor=white" />
  <img alt="Audit" src="https://img.shields.io/badge/Audited-Omniscia-6366F1" />
  <img alt="License" src="https://img.shields.io/badge/License-MIT-22C55E" />
</p>

---

## The Problem with DeFi Lending Today

Every existing DeFi lending protocol requires you to lock up more than you borrow — usually **150% or more**. Want to borrow $100? Lock up $150 first.

This model works for traders, but it excludes the majority of people who simply need access to credit. Traditional finance solved this with credit scores. DeFi hasn't, until now.

---

## What Avocado Fund Does

**Avocado Fund replaces collateral with identity.**

- ✅ **Lenders** deposit USDC and earn yield from real borrower interest — not token inflation, not liquidation mechanics. Real money, real returns.
- ✅ **Borrowers** verify their identity once with Persona KYC, get an instant credit line, and borrow USDC with no collateral required.
- ✅ **AVO Score** — every repayment you make is recorded on-chain. Your credit history belongs to you, lives on Arbitrum, and grows every time you repay on time.

---

## For Lenders

Deposit USDC → receive `avUSDC` shares → earn as borrowers repay interest.

The vault follows the **ERC-4626 tokenised vault standard**. As interest accrues, the share price rises automatically — no staking, no claiming. Just hold avUSDC and watch it appreciate.

| Property | Value |
|---|---|
| Vault standard | ERC-4626 |
| Borrow rate | 12% APR (fixed) |
| Net lender yield | 12% × utilisation × 0.9 (10% performance fee to treasury) |
| Vault cap | $5,000,000 USDC |
| Withdrawal | Anytime — no lockup, no queue |
| avUSDC decimals | 12 (inflation-attack protected) |

---

## For Borrowers

1. **Verify** — complete Persona KYC (government ID + biometric liveness). One-time.
2. **Get approved** — receive your starting credit tier and AVO Score.
3. **Borrow** — call `borrow()`, USDC arrives in your wallet. Interest accrues per second at 12% APR.
4. **Repay** — repay any time. No fixed deadlines.
5. **Level up** — every on-time repayment raises your AVO Score and unlocks a higher credit limit.

### Credit Tiers

| AVO Score | Credit Limit | Tier |
|---|---|---|
| 75+ | **$10,000** | 5 — Established |
| 65–74 | $1,000 | 4 — Trusted |
| 50–64 | $500 | 3 — Good |
| 30–49 | $250 | 2 — Building |
| 10–29 | $100 | 1 — Starting |
| < 10 | $25 | 0 — Entry |

Everyone starts at Tier 0 on first KYC approval. Build up from there — your history is yours forever, on-chain.

---

## AVO Score — Your On-Chain Credit Rating

AVO Score (0–100) determines your tier and credit limit. It is computed from seven components:

| Component | Max Points | Description |
|---|---|---|
| Identity (Persona KYC) | 15 | Verification status and document type |
| Bureau score | 20 | Traditional credit score (300–850), 0 if no file |
| Repayment history | 30 | On-time repayment ratio across all completed loans |
| Account tenure | 10 | Time since first approval |
| Volume repaid | 10 | Lifetime USDC repaid |
| Utilisation | 10 | Always 10 — borrowing does **not** penalise your score |
| Bonus | 5 | Perfect record (5+ loans, all on time) + long-term loyalty |

Penalties: −5 per late repayment (max −15). Defaulters are removed from the protocol.

> **Design principle:** We built AVO Score so that responsible borrowers are rewarded, not punished for using credit. The utilisation pillar always awards full points — only repayment behaviour affects your score.

---

## Smart Contracts

All contracts are open-source and Omniscia-audited.

| Contract | Address (Arbitrum One) | Description |
|---|---|---|
| **AvocadoVault** | [`0xa3185e9AD376BC95600b65648bac02aF23653741`](https://arbiscan.io/address/0xa3185e9ad376bc95600b65648bac02af23653741) | ERC-4626 USDC vault — issues avUSDC shares, accrues interest, 10% performance fee |
| **AvocadoLending** | [`0xFF27bAeE76495a33CAed3c7cad31E404034b8911`](https://arbiscan.io/address/0xff27baee76495a33caed3c7cad31e404034b8911) | Credit line management — KYC gate, borrow/repay, per-second interest, default tracking |
| **USDC (native)** | [`0xaf88d065e77c8cC2239327C5EDb3A432268e5831`](https://arbiscan.io/address/0xaf88d065e77c8cc2239327c5edb3a432268e5831) | Circle's native USDC on Arbitrum |
| **AVOToken** | Not yet deployed | ERC-20 governance + rewards token (TGE ~Aug 2026) |

### Contract Architecture

```
Lenders                                 Borrowers
   │                                        │
   ▼                                        ▼
USDC ──► AvocadoVault (ERC-4626) ◄──── Persona KYC
          │    avUSDC shares │                │
          │                  │         AvocadoLending
          │    interest ◄────┘         (borrow / repay)
          │                                   │
          └──── share price rises ◄── interest payments
```

### Security Properties

- **Ownable2Step** on all owner-controlled contracts — two-step ownership transfers prevent accidents
- **ReentrancyGuard** on all state-changing functions
- **Pausable** — vault and lending can be paused independently by the owner
- **SafeERC20** for all USDC transfers
- **Per-second interest** — interest accrues continuously, preventing flash-loan manipulation
- **Sybil resistance** — Persona KYC uses a PII-derived nullifier; one credit line per real human
- **Default declaration** — admin can mark defaulters; they are blacklisted on-chain and reported to credit bureaus

---

## Audit

Audited by [Omniscia](https://omniscia.io) — **19 findings** (4 static analysis + 15 manual), **all remediated** before mainnet deployment.

Final audited commit: `28abe24`

---

## Build & Test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
cd contracts
forge install       # install dependencies
forge build         # compile
forge test -vvv     # run 124 tests
```

---

## Roadmap

| Feature | Status |
|---|---|
| AvocadoVault + AvocadoLending on Arbitrum | ✅ Live |
| Persona KYC + AVO Score | ✅ Live |
| Cross-chain deposits via LiFi bridge | ✅ Live |
| AVOToken deployment | 🔜 ~Aug 2026 |
| Multisig ownership (Gnosis Safe) | 🔜 In progress |
| DeFi Llama adapter | 🔜 Pending submission |
| Credit bureau reporting for defaults | 🔜 Planned |

---

## Links

| | |
|---|---|
| 🌐 App | https://avocado.fund |
| 🏦 Vault | https://avocado.fund/vault |
| 💳 Borrow | https://avocado.fund/borrow |
| 📊 Analytics | https://avocado.fund/analytics |
| 🔍 Transparency | https://avocado.fund/transparency |
| 📖 Docs | https://avocado.fund/docs |
| 🐦 X / Twitter | https://x.com/_avocadofund |
| 💬 Telegram | https://t.me/avocadofund |

---

## License

[MIT](LICENSE)
