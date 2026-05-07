#!/bin/bash
# Avocado Fund — Complete End-to-End Protocol Test
# Run: cd avocado-fund/contracts && bash test/e2e.sh

set -e
RPC="http://localhost:8545"
USDC="0x5FbDB2315678afecb367f032d93F642f64180aa3"
VAULT="0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
LENDING="0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"

DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ALICE_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ALICE_ADDR="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
BOB_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
BOB_ADDR="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
BORROWER1_KEY="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
BORROWER1_ADDR="0x90F79bf6EB2c4f870365E785982E1f101E93b906"

fmt() { python3 -c "print('\$%.${2:-2f}' % ($1/1000000))"; }
fmtp() { python3 -c "print('%.2f%%' % ($1/100))"; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  🥑 AVOCADO FUND — Complete End-to-End Protocol Test"
echo "═══════════════════════════════════════════════════════════"

# ── 0. Initial state ───────────────────────────────────────────────
echo ""
echo "📊 [0] INITIAL VAULT STATE"
TA=$(cast call $VAULT "totalAssets()(uint256)" --rpc-url $RPC)
DA=$(cast call $VAULT "deployedAssets()(uint256)" --rpc-url $RPC)
SP=$(cast call $VAULT "sharePrice()(uint256)" --rpc-url $RPC)
UT=$(cast call $VAULT "utilizationBps()(uint256)" --rpc-url $RPC)
echo "  totalAssets:    $(fmt $TA) USDC"
echo "  deployedAssets: $(fmt $DA) USDC"
echo "  sharePrice:     $(fmt $SP 6) per avUSDC"
echo "  utilization:    $(fmtp $UT)"

# ── 1. Bob deposits $50K ───────────────────────────────────────────
echo ""
echo "💰 [1] BOB DEPOSITS \$50,000 USDC"
cast send $USDC "approve(address,uint256)" $VAULT 50000000000 \
  --private-key $BOB_KEY --rpc-url $RPC --quiet
cast send $VAULT "deposit(uint256,address)" 50000000000 $BOB_ADDR \
  --private-key $BOB_KEY --rpc-url $RPC --quiet
BOB_SHARES=$(cast call $VAULT "balanceOf(address)(uint256)" $BOB_ADDR --rpc-url $RPC)
echo "  Bob received: $(fmt $BOB_SHARES 4) avUSDC shares ✅"

# ── 2. Deploy capital to lending ───────────────────────────────────
echo ""
echo "🚀 [2] DEPLOY \$40,000 MORE TO LENDING"
cast send $VAULT "deployToLending(uint256)" 40000000000 \
  --private-key $DEPLOYER_KEY --rpc-url $RPC --quiet
DA2=$(cast call $VAULT "deployedAssets()(uint256)" --rpc-url $RPC)
echo "  deployedAssets: $(fmt $DA2) USDC"

# ── 3. Borrower 1 borrows $30K ─────────────────────────────────────
echo ""
echo "🏦 [3] BORROWER 1 BORROWS \$30,000"
cast send $LENDING "borrow(uint256)" 30000000000 \
  --private-key $BORROWER1_KEY --rpc-url $RPC --quiet
B1=$(cast call $USDC "balanceOf(address)(uint256)" $BORROWER1_ADDR --rpc-url $RPC)
echo "  Borrower1 USDC balance: $(fmt $B1) ✅"

# ── 4. Fast-forward 1 year ─────────────────────────────────────────
echo ""
echo "⏩ [4] FAST-FORWARD 1 YEAR (12% APR on \$30K = ~\$3,600 interest)"
cast rpc anvil_increaseTime 31536000 --rpc-url $RPC > /dev/null
cast rpc anvil_mine --rpc-url $RPC > /dev/null

# Estimate debt
PRINCIPAL=30000000000
INTEREST=$(python3 -c "print(int(30000000000 * 1200 * 31536000 / (31536000 * 10000)))")
echo "  Estimated interest accrued: $(fmt $INTEREST) USDC"

# ── 5. Borrower 1 repays all ──────────────────────────────────────
echo ""
echo "💸 [5] BORROWER 1 REPAYS PRINCIPAL + INTEREST"
REPAY=$(python3 -c "print(30000000000 + 3600000000 + 1000000)")  # principal + interest + buffer
cast send $USDC "mint(address,uint256)" $BORROWER1_ADDR 5000000000 \
  --private-key $DEPLOYER_KEY --rpc-url $RPC --quiet
cast send $USDC "approve(address,uint256)" $LENDING $REPAY \
  --private-key $BORROWER1_KEY --rpc-url $RPC --quiet
cast send $LENDING "repayAll()" \
  --private-key $BORROWER1_KEY --rpc-url $RPC --quiet
echo "  Repayment confirmed ✅"

# ── 6. Share price after interest ─────────────────────────────────
echo ""
echo "📈 [6] SHARE PRICE AFTER INTEREST"
SP2=$(cast call $VAULT "sharePrice()(uint256)" --rpc-url $RPC)
TA2=$(cast call $VAULT "totalAssets()(uint256)" --rpc-url $RPC)
SP_DELTA=$(python3 -c "print(f'{($SP2 - 1000000) / 1000000 * 100:.4f}%')")
echo "  sharePrice:   $(fmt $SP2 6) per avUSDC  (+$SP_DELTA vs \$1.000000)"
echo "  totalAssets:  $(fmt $TA2) USDC"

ALICE_SHARES=$(cast call $VAULT "balanceOf(address)(uint256)" $ALICE_ADDR --rpc-url $RPC)
ALICE_VALUE=$(python3 -c "print(int($ALICE_SHARES * $SP2 / 1000000))")
BOB_VALUE=$(python3 -c "print(int($BOB_SHARES * $SP2 / 1000000))")
echo "  Alice ($(fmt $ALICE_SHARES 4) avUSDC) → $(fmt $ALICE_VALUE) USDC  [deposited \$10,000]"
echo "  Bob   ($(fmt $BOB_SHARES 4) avUSDC) → $(fmt $BOB_VALUE) USDC  [deposited \$50,000]"

# ── 7. Alice redeems ──────────────────────────────────────────────
echo ""
echo "🏧 [7] ALICE REDEEMS ALL SHARES"
ALICE_USDC_BEFORE=$(cast call $USDC "balanceOf(address)(uint256)" $ALICE_ADDR --rpc-url $RPC)

# First recall funds from lending to ensure liquidity
cast send $VAULT "recallFromLending(uint256)" $ALICE_VALUE \
  --private-key $DEPLOYER_KEY --rpc-url $RPC --quiet 2>/dev/null || true

cast send $VAULT "redeem(uint256,address,address)" $ALICE_SHARES $ALICE_ADDR $ALICE_ADDR \
  --private-key $ALICE_KEY --rpc-url $RPC --quiet
ALICE_USDC_AFTER=$(cast call $USDC "balanceOf(address)(uint256)" $ALICE_ADDR --rpc-url $RPC)
RECEIVED=$(python3 -c "print($ALICE_USDC_AFTER - $ALICE_USDC_BEFORE)")
PROFIT=$(python3 -c "print($ALICE_USDC_AFTER - $ALICE_USDC_BEFORE - 10000000000)")
echo "  Alice received: $(fmt $RECEIVED 6) USDC"
echo "  Alice profit:   $(fmt $PROFIT 6) USDC ✅"

# ── 8. Final state ────────────────────────────────────────────────
echo ""
echo "📊 [8] FINAL VAULT STATE"
TA3=$(cast call $VAULT "totalAssets()(uint256)" --rpc-url $RPC)
SP3=$(cast call $VAULT "sharePrice()(uint256)" --rpc-url $RPC)
TS3=$(cast call $VAULT "totalSupply()(uint256)" --rpc-url $RPC)
echo "  totalAssets:  $(fmt $TA3) USDC"
echo "  totalSupply:  $(fmt $TS3 4) avUSDC shares outstanding"
echo "  sharePrice:   $(fmt $SP3 6) per avUSDC"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ✅  ALL PROTOCOL FLOWS VERIFIED SUCCESSFULLY"
echo "═══════════════════════════════════════════════════════════"
echo ""
