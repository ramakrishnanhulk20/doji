#!/usr/bin/env bash
# Sets up the live Wave 2 pay-down demo on Mezo testnet against the contracts in deployments/31611-wave2.json, with
# cast. The DEPLOYER posts three fresh offers (12 Nov and 19 Nov parked in the sMUSD vault, 26 Nov plain). The
# BORROWER locks 0.01 test BTC for 28 days and borrows 10 MUSD from the 19 Nov offer, then in later blocks votes the
# new position 50/50 on the MUSD/mT and mcbBTC/BTC pools and names PayDown its reward operator. The DEPLOYER adds
# incentives to both pools' incentive contracts, claims its 19 Nov credit units and lists 5 of them on UnitMarket at
# 0.99 MUSD each, and the BUYER buys 2. Every call is simulated from its sender before it is sent. Prints every
# transaction's label and hash, then a summary of the demo position and the listing.
#
# What it does NOT prove: the pay-down itself. Incentives become claimable only after the epoch ends (Thursday
# 00:00 UTC), and the keeper's harvest then turns them into repayment. An incentive call that reverts in simulation
# is skipped and reported, never retried with another amount or token.
#
# Safe to run again after a failure: every finished transaction is recorded in scratchpad/wave2-live/progress.env
# and skipped on the next run, so no offer, transfer, vote or purchase is sent twice. That file is tied to this
# deployment's CreditMarkets and refused for any other.
#
# Cost per run: 0.012 test BTC to the borrower (0.01 of it locked), 110 test MUSD in offers and 20 test MUSD plus
# 0.0003 test BTC in incentives from DEPLOYER, about 1.98 test MUSD from BUYER for the units, and testnet gas.
#
# Usage, from anywhere: bash packages/contracts/script/wave2-live.sh
# Reads DEPLOYER_*, BORROWER_*, BUYER_* and MEZO_TESTNET_RPC from packages/contracts/.env. Keys go to cast only and
# are never printed.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CONTRACTS_DIR/../.." && pwd)"
SCRATCH_DIR="$REPO_DIR/scratchpad/wave2-live"
PROGRESS="$SCRATCH_DIR/progress.env"
TX_LOG="$SCRATCH_DIR/transactions.txt"
SKIPPED="$SCRATCH_DIR/skipped.txt"
CHAIN_ID=31611
EXPLORER="https://explorer.test.mezo.org"
RECORD="deployments/$CHAIN_ID-wave2.json"

MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
BTC=0x7b7C000000000000000000000000000000000000
VEBTC=0xB63fcCd03521Cf21907627bd7fA465C129479231
POOL_MUSD_MT=0x0E6BD7E52e4491320012f8C9E6161cD915BB0D19
BRIBE_MUSD_MT=0xAa8a371f64F1bc444B5e4cb68b00562cCF0f3796
POOL_MCBBTC_BTC=0xc8BA1027e1D4f9C646B9963Eab89B1e7CF2A476E
BRIBE_MCBBTC_BTC=0x6E928BeEDd77F1DBf3b0FDb8b43F7b58678ba0b7

NOV12=1794441600
NOV19=1795046400
NOV26=1795651200
# The epoch the votes and incentives must land in ends Thursday 5 Nov 00:00 UTC.
EPOCH_END=1793836800

OFFER_12_APR=600
OFFER_19_APR=650
OFFER_26_APR=700
OFFER_12_WEI=40000000000000000000
OFFER_19_WEI=40000000000000000000
OFFER_26_WEI=30000000000000000000
OFFERS_TOTAL_WEI=110000000000000000000
BORROWER_BTC_WEI=12000000000000000
LOCK_BTC_WEI=10000000000000000
LOCK_SECONDS=2419200
BORROW_WEI=10000000000000000000
MAX_APR_BPS=650
INCENTIVE_MUSD_WEI=20000000000000000000
INCENTIVE_BTC_WEI=300000000000000
LIST_UNITS_WEI=5000000000000000000
LIST_PRICE_WEI=990000000000000000
LIST_EXPIRY=$((NOV19 - 86400))
BUY_UNITS_WEI=2000000000000000000

# Two to four times what each call measured on the mainnet fork or the earlier testnet runs; testnet gas is priced
# at a few hundred wei, so the headroom costs nothing.
GAS_APPROVE=150000
GAS_POST=1000000
GAS_VALUE=100000
GAS_LOCK_BORROW=2500000
GAS_VOTE=2000000
GAS_OPERATOR=300000
GAS_NOTIFY=800000
GAS_CLAIM=500000
GAS_LIST=800000
GAS_BUY=800000

# Some nodes behind the public RPC lag the others, so a read, a receipt or a simulation right after a receipt is
# asked again for up to 120 s before it counts as failed.
WAIT_TRIES=40
WAIT_SECONDS=3

die() { echo "WAVE 2 LIVE SETUP STOPPED: $*" >&2; exit 1; }

# python is a native Windows program on this machine, so it needs D:/ paths rather than /d/ paths.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

pick_python() {
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import json" >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done
  die "python is needed to read the record and the receipts"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
musd() { cast from-wei "$1"; }

cd "$CONTRACTS_DIR"
[ -f .env ] || die "packages/contracts/.env is missing"
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }
DEPLOYER="$(env_value DEPLOYER_ADDRESS)"
BORROWER="$(env_value BORROWER_ADDRESS)"
BUYER="$(env_value BUYER_ADDRESS)"
DEPLOYER_KEY="$(env_value DEPLOYER_PRIVATE_KEY)"
BORROWER_KEY="$(env_value BORROWER_PRIVATE_KEY)"
BUYER_KEY="$(env_value BUYER_PRIVATE_KEY)"
RPC="${MEZO_TESTNET_RPC:-$(env_value MEZO_TESTNET_RPC)}"
[ -n "$RPC" ] || die "MEZO_TESTNET_RPC is not set"
for who in DEPLOYER BORROWER BUYER; do
  address="${!who}"
  key_var="${who}_KEY"
  [[ "$address" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "${who}_ADDRESS in .env is not an address"
  [ -n "${!key_var}" ] || die "${who}_PRIVATE_KEY must be set in .env"
  [ "$(lower "$(cast wallet address --private-key "${!key_var}")")" = "$(lower "$address")" ] \
    || die "${who}_PRIVATE_KEY does not belong to ${who}_ADDRESS"
done
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || die "MEZO_TESTNET_RPC is not Mezo testnet (chain $CHAIN_ID)"
PY="$(pick_python)"

[ -f "$RECORD" ] || die "$RECORD is missing; deploy Wave 2 first"
record() {
  "$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(native_path "$CONTRACTS_DIR/$RECORD")" "$1" \
    | tr -d '\r'
}
[ "$(record broadcast)" = "True" ] || die "$RECORD is not a broadcast record"
[ "$(record chainId)" = "$CHAIN_ID" ] || die "$RECORD is not for chain $CHAIN_ID"
CM="$(record creditMarkets)"
LM="$(record loanManager)"
PD="$(record payDown)"
UM="$(record unitMarket)"
PT="$(record passThrough)"
POOLS_VOTER="$(record poolsVoter)"
for target in "$CM" "$LM" "$PD" "$UM"; do
  [[ "$target" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$RECORD names a bad address: $target"
  [ "$(cast codesize "$target" --rpc-url "$RPC")" != "0" ] || die "no code at $target"
done
[ "$(lower "$(cast call "$PD" "loanManager()(address)" --rpc-url "$RPC")")" = "$(lower "$LM")" ] \
  || die "PayDown does not point at this LoanManager"
[ "$(lower "$(cast call "$UM" "creditMarkets()(address)" --rpc-url "$RPC")")" = "$(lower "$CM")" ] \
  || die "UnitMarket does not point at this CreditMarkets"

mkdir -p "$SCRATCH_DIR"
touch "$PROGRESS" "$TX_LOG" "$SKIPPED"
done_value() { grep -E "^$1=" "$PROGRESS" | tail -1 | cut -d= -f2- || true; }
mark() { echo "$1=$2" >> "$PROGRESS"; }
if [ -n "$(done_value CREDIT_MARKETS)" ]; then
  [ "$(lower "$(done_value CREDIT_MARKETS)")" = "$(lower "$CM")" ] \
    || die "$PROGRESS belongs to CreditMarkets $(done_value CREDIT_MARKETS), not $CM; move it aside first"
else
  mark CREDIT_MARKETS "$CM"
fi

for maturity in "$NOV12" "$NOV19" "$NOV26"; do
  [ "$(cast call "$CM" "isValidMaturity(uint64)(bool)" "$maturity" --rpc-url "$RPC")" = "true" ] \
    || die "maturity $maturity is not open on CreditMarkets"
done

link() { echo "$EXPLORER/tx/$1"; }

# A lagging node can report an old pending nonce, so each wallet's nonce is read a few times, the highest kept, and
# tracked here from then on.
fresh_nonce() {
  local best=0 n
  for _ in 1 2 3; do
    n="$(cast nonce "$1" --block pending --rpc-url "$RPC")"
    [ "$n" -gt "$best" ] && best="$n"
  done
  echo "$best"
}
DEPLOYER_NONCE="$(fresh_nonce "$DEPLOYER")"
BORROWER_NONCE="$(fresh_nonce "$BORROWER")"
BUYER_NONCE="$(fresh_nonce "$BUYER")"

# Reads a value at a pinned block, asking again while a lagging node has not reached that block yet. Prints the
# first word of the first line, which is the decoded value without cast's scientific-notation hint.
read_at() {
  local block="$1"
  shift
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast call "$@" --block "$block" --rpc-url "$RPC" 2>/dev/null)"; then
      printf '%s' "$out" | head -1 | awk '{print $1}'
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read $* at block $block"
}

# Same, for a raw return value the caller decodes itself.
read_raw_at() {
  local block="$1"
  shift
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast call "$@" --block "$block" --rpc-url "$RPC" 2>/dev/null)"; then
      printf '%s' "$out" | tr -d '\r'
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read $* at block $block"
}

# Simulates a call from its sender, asking again while a lagging node has not seen the previous receipt yet. Sets
# SIM_ERR to the last error and returns non-zero if it still fails after 120 s.
SIM_ERR=""
try_simulate() {
  local from="$1"
  shift
  SIM_ERR=""
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if SIM_ERR="$(cast call --from "$from" "$@" --rpc-url "$RPC" 2>&1 >/dev/null)"; then
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  return 1
}

receipt_status() {
  local status=""
  for _ in $(seq 1 "$WAIT_TRIES"); do
    status="$(cast receipt --async "$1" status --rpc-url "$RPC" 2>/dev/null || true)"
    [ -n "$status" ] && { printf '%s' "$status"; return 0; }
    sleep "$WAIT_SECONDS"
  done
  return 1
}

receipt_field() {
  local out=""
  for _ in $(seq 1 "$WAIT_TRIES"); do
    out="$(cast receipt "$1" "$2" --rpc-url "$RPC" 2>/dev/null || true)"
    [ -n "$out" ] && { printf '%s' "$out" | awk '{print $1}'; return 0; }
    sleep "$WAIT_SECONDS"
  done
  die "could not read $2 of receipt $1"
}

# send <label> <wallet> <gas> <cast send arguments...>: simulates from the wallet, sends with the tracked nonce and
# an explicit gas limit, waits for the receipt, logs the transaction and sets SENT_HASH and SENT_BLOCK. <wallet> is
# DEPLOYER, BORROWER or BUYER.
SENT_HASH=""
SENT_BLOCK=""
send() {
  local label="$1" who="$2" gas="$3"
  shift 3
  local from="${!who}" key_var="${who}_KEY" nonce_var="${who}_NONCE"
  try_simulate "$from" "$@" || die "$label: simulation from $from still fails after $((WAIT_TRIES * WAIT_SECONDS)) s: $SIM_ERR"
  SENT_HASH="$(cast send --async --private-key "${!key_var}" --nonce "${!nonce_var}" --gas-limit "$gas" "$@" --rpc-url "$RPC")"
  [[ "$SENT_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "$label: cast send returned no transaction hash"
  printf -v "$nonce_var" '%d' $((${!nonce_var} + 1))
  local status
  status="$(receipt_status "$SENT_HASH")" || die "$label: no receipt after $((WAIT_TRIES * WAIT_SECONDS)) s for $SENT_HASH"
  case "$(lower "$(printf '%s' "$status" | awk '{print $1}')")" in
    true | 1 | 0x1) ;;
    *) die "$label failed: status $status, $(link "$SENT_HASH")" ;;
  esac
  SENT_BLOCK="$(receipt_field "$SENT_HASH" blockNumber)"
  local gas_used
  gas_used="$(receipt_field "$SENT_HASH" gasUsed)"
  echo "$label|$SENT_HASH|$SENT_BLOCK|$gas_used" >> "$TX_LOG"
  echo "   tx $label: ok $SENT_HASH block $SENT_BLOCK gas $gas_used $(link "$SENT_HASH")"
}

# step <key> <label> <wallet> <gas> <cast send arguments...>: sends once. A key already in the progress file means
# an earlier run sent it, so it is skipped and its hash and block are read back from there.
step() {
  local key="$1" label="$2"
  shift 2
  if [ -n "$(done_value "${key}_HASH")" ]; then
    SENT_HASH="$(done_value "${key}_HASH")"
    SENT_BLOCK="$(done_value "${key}_BLOCK")"
    echo "   tx $label: sent in an earlier run, $SENT_HASH block $SENT_BLOCK"
    return 0
  fi
  send "$label" "$@"
  mark "${key}_HASH" "$SENT_HASH"
  mark "${key}_BLOCK" "$SENT_BLOCK"
}

# event_value <hash> <emitter> <event signature> <topic index or data word>: prints one field of the first matching
# log in the receipt as a decimal number. A data word is written d0, d1 and so on.
event_value() {
  local topic out value rc
  topic="$(cast keccak "$3")"
  for _ in $(seq 1 "$WAIT_TRIES"); do
    out="$(cast receipt "$1" --json --rpc-url "$RPC" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      # Exit 2 means the node answered without the logs (seen live from a lagging node), so it is asked again; exit
      # 1 means a full receipt that lacks the event, which no retry can fix.
      value="$(printf '%s' "$out" | "$PY" -I -c '
import json, sys
emitter, topic, field = sys.argv[1].lower(), sys.argv[2].lower(), sys.argv[3]
try:
    receipt = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(2)
logs = receipt.get("logs") if isinstance(receipt, dict) else None
if not isinstance(logs, list):
    sys.exit(2)
for log in logs:
    if log["address"].lower() == emitter and log["topics"][0].lower() == topic:
        if field.startswith("d"):
            word = int(field[1:])
            data = log["data"][2:]
            print(int(data[64 * word:64 * (word + 1)], 16))
        else:
            print(int(log["topics"][int(field)], 16))
        sys.exit(0)
sys.exit(1)
' "$2" "$topic" "$4")" && rc=0 || rc=$?
      case "$rc" in
        0) printf '%s' "$value" | tr -d '\r'; return 0 ;;
        1) die "no $3 event from $2 in $1" ;;
      esac
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read the receipt of $1"
}

# remember <key> <command...>: records the command's answer under <key>. A die inside $(...) only ends the subshell,
# so the failure is caught here and stops the run instead of recording an empty value.
remember() {
  local key="$1" value
  shift
  value="$("$@")" || die "could not work out $key"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$key came back as '$value', not a number"
  mark "$key" "$value"
}

echo "== Wave 2 contracts"
echo "   CreditMarkets $CM"
echo "   LoanManager   $LM"
echo "   PayDown       $PD"
echo "   UnitMarket    $UM"
echo "   PassThrough   $PT"

echo "== Step 5: fresh offers from the deployer"
step APPROVE_OFFERS "MUSD.approve(CreditMarkets, 110 MUSD)" DEPLOYER "$GAS_APPROVE" \
  "$MUSD" "approve(address,uint256)" "$CM" "$OFFERS_TOTAL_WEI"
post_offer() {
  local key="$1" fn="$2" maturity="$3" apr="$4" amount="$5"
  step "$key" "CreditMarkets.$fn($maturity, $apr, $(musd "$amount") MUSD)" DEPLOYER "$GAS_POST" \
    "$CM" "$fn(uint64,uint16,uint128)" "$maturity" "$apr" "$amount"
  if [ -z "$(done_value "${key}_ID")" ]; then
    remember "${key}_ID" event_value "$SENT_HASH" "$CM" "OfferPosted(uint256,address,uint64,uint16,uint128)" 1
  fi
  echo "   offer $(done_value "${key}_ID") posted"
}
post_offer OFFER_NOV12 postParkedOffer "$NOV12" "$OFFER_12_APR" "$OFFER_12_WEI"
post_offer OFFER_NOV19 postParkedOffer "$NOV19" "$OFFER_19_APR" "$OFFER_19_WEI"
post_offer OFFER_NOV26 postOffer "$NOV26" "$OFFER_26_APR" "$OFFER_26_WEI"
OFFER_19_ID="$(done_value OFFER_NOV19_ID)"
[[ "$OFFER_19_ID" =~ ^[0-9]+$ ]] || die "no offer id recorded for the 19 Nov offer"

echo "== Step 6: the demo borrower locks 0.01 BTC for 28 days and borrows 10 MUSD from offer $OFFER_19_ID"
step FUND_BORROWER "send 0.012 BTC to the borrower" DEPLOYER "$GAS_VALUE" "$BORROWER" --value "$BORROWER_BTC_WEI"
step APPROVE_LOCK "BTC.approve(LoanManager, 0.01 BTC)" BORROWER "$GAS_APPROVE" \
  "$BTC" "approve(address,uint256)" "$LM" "$LOCK_BTC_WEI"
step LOCK_BORROW "LoanManager.lockAndBorrow(0.01 BTC, $LOCK_SECONDS s, $NOV19, [$OFFER_19_ID], [10 MUSD], $MAX_APR_BPS)" \
  BORROWER "$GAS_LOCK_BORROW" \
  "$LM" "lockAndBorrow(uint256,uint256,uint64,uint256[],uint128[],uint16)" \
  "$LOCK_BTC_WEI" "$LOCK_SECONDS" "$NOV19" "[$OFFER_19_ID]" "[$BORROW_WEI]" "$MAX_APR_BPS"
BORROW_HASH="$SENT_HASH"
BORROW_BLOCK="$SENT_BLOCK"
if [ -z "$(done_value TOKEN_ID)" ]; then
  remember TOKEN_ID event_value "$BORROW_HASH" "$LM" "Deposited(uint256,address)" 1
fi
TOKEN_ID="$(done_value TOKEN_ID)"
[[ "$TOKEN_ID" =~ ^[0-9]+$ ]] || die "no tokenId recorded for the demo position"
PRINCIPAL="$(event_value "$BORROW_HASH" "$LM" "Borrowed(uint256,address,uint64,uint256,uint256)" d0)"
FACE="$(event_value "$BORROW_HASH" "$LM" "Borrowed(uint256,address,uint64,uint256,uint256)" d1)"
OWED_AT_BORROW="$(read_at "$BORROW_BLOCK" "$LM" "owedOf(uint256)(uint256)" "$TOKEN_ID")"
echo "   veBTC #$TOKEN_ID: principal $(musd "$PRINCIPAL") MUSD, face $(musd "$FACE") MUSD, owed $(musd "$OWED_AT_BORROW") MUSD"

echo "== Step 7: the borrower votes #$TOKEN_ID and names PayDown its reward operator, in later blocks"
step VOTE "LoanManager.vote($TOKEN_ID, [MUSD/mT, mcbBTC/BTC], [5000, 5000])" BORROWER "$GAS_VOTE" \
  "$LM" "vote(uint256,address[],uint256[])" "$TOKEN_ID" "[$POOL_MUSD_MT,$POOL_MCBBTC_BTC]" "[5000,5000]"
VOTE_BLOCK="$SENT_BLOCK"
[ "$VOTE_BLOCK" -gt "$BORROW_BLOCK" ] || die "the vote landed in block $VOTE_BLOCK, not after the deposit's $BORROW_BLOCK"
echo "   vote in block $VOTE_BLOCK, after the deposit's block $BORROW_BLOCK"
step OPERATOR "LoanManager.setRewardOperator($TOKEN_ID, PayDown)" BORROWER "$GAS_OPERATOR" \
  "$LM" "setRewardOperator(uint256,address)" "$TOKEN_ID" "$PD"
OPERATOR_BLOCK="$SENT_BLOCK"
read -r POS_BORROWER POS_OPERATOR < <(read_raw_at "$OPERATOR_BLOCK" "$LM" "positionOf(uint256)" "$TOKEN_ID" | "$PY" -I -c '
import sys
raw = sys.stdin.read().strip()[2:]
print("0x" + raw[24:64], "0x" + raw[88:128])' | tr -d '\r') || true
echo "   positionOf($TOKEN_ID): borrower $POS_BORROWER, reward operator $POS_OPERATOR"
[ "$(lower "$POS_OPERATOR")" = "$(lower "$PD")" ] || die "the reward operator reads $POS_OPERATOR, not PayDown $PD"
[ "$(lower "$POS_BORROWER")" = "$(lower "$BORROWER")" ] || die "the position's borrower reads $POS_BORROWER, not $BORROWER"

echo "== Step 8: incentives from the deployer"
# The approval goes first because notifyRewardAmount pulls the tokens, so a simulation before it would always fail
# on the allowance. A real refusal still shows after the approval and is reported, not worked around.
incentive() {
  local key="$1" name="$2" token="$3" amount="$4" bribe="$5" shown="$6"
  if [ -n "$(done_value "${key}_HASH")" ] || [ -n "$(done_value "${key}_SKIPPED")" ]; then
    echo "   $name: handled in an earlier run"
    return 0
  fi
  step "${key}_APPROVE" "$name: approve($bribe, $shown)" DEPLOYER "$GAS_APPROVE" \
    "$token" "approve(address,uint256)" "$bribe" "$amount"
  if try_simulate "$DEPLOYER" "$bribe" "notifyRewardAmount(address,uint256)" "$token" "$amount"; then
    step "$key" "$name: notifyRewardAmount($shown)" DEPLOYER "$GAS_NOTIFY" \
      "$bribe" "notifyRewardAmount(address,uint256)" "$token" "$amount"
  else
    local reason
    reason="$(printf '%s' "$SIM_ERR" | tr '\r\n' '  ')"
    echo "   SKIPPED $name: notifyRewardAmount($shown) reverts in simulation: $reason"
    echo "$name|$shown|$reason" >> "$SKIPPED"
    mark "${key}_SKIPPED" yes
  fi
}
incentive NOTIFY_MUSD "MUSD/mT incentives" "$MUSD" "$INCENTIVE_MUSD_WEI" "$BRIBE_MUSD_MT" "20 MUSD"
incentive NOTIFY_BTC "mcbBTC/BTC incentives" "$BTC" "$INCENTIVE_BTC_WEI" "$BRIBE_MCBBTC_BTC" "0.0003 BTC"

echo "== Step 9: the deployer lists 19 Nov units on UnitMarket and the buyer buys 2"
step CLAIM_UNITS "CreditMarkets.claimUnits($NOV19)" DEPLOYER "$GAS_CLAIM" "$CM" "claimUnits(uint64)" "$NOV19"
if [ -z "$(done_value UNITS_MINTED)" ]; then
  remember UNITS_MINTED event_value "$SENT_HASH" "$CM" "UnitsClaimed(address,uint64,uint256)" d0
fi
echo "   units minted to the deployer: $(musd "$(done_value UNITS_MINTED)")"
LIST_DATA="$(cast abi-encode "f(uint128,uint64)" "$LIST_PRICE_WEI" "$LIST_EXPIRY")"
step LIST "CreditMarkets.safeTransferFrom(deployer, UnitMarket, $NOV19, 5 units, 0.99 MUSD each until $LIST_EXPIRY)" \
  DEPLOYER "$GAS_LIST" \
  "$CM" "safeTransferFrom(address,address,uint256,uint256,bytes)" "$DEPLOYER" "$UM" "$NOV19" "$LIST_UNITS_WEI" "$LIST_DATA"
if [ -z "$(done_value LISTING_ID)" ]; then
  remember LISTING_ID event_value "$SENT_HASH" "$UM" "Listed(uint256,address,uint64,uint128,uint128,uint64,uint16)" 1
fi
LISTING_ID="$(done_value LISTING_ID)"
[[ "$LISTING_ID" =~ ^[0-9]+$ ]] || die "no listing id recorded"
echo "   listing $LISTING_ID created"
if [ -z "$(done_value BUY_COST)" ]; then
  remember BUY_COST read_at "$SENT_BLOCK" "$UM" "quoteBuy(uint256,uint128)(uint256,uint256)" "$LISTING_ID" "$BUY_UNITS_WEI"
fi
BUY_COST="$(done_value BUY_COST)"
echo "   quoteBuy($LISTING_ID, 2 units) = $(musd "$BUY_COST") MUSD"
step BUY_APPROVE "MUSD.approve(UnitMarket, $(musd "$BUY_COST") MUSD) by the buyer" BUYER "$GAS_APPROVE" \
  "$MUSD" "approve(address,uint256)" "$UM" "$BUY_COST"
step BUY "UnitMarket.buy($LISTING_ID, 2 units, max 0.99 MUSD each) by the buyer" BUYER "$GAS_BUY" \
  "$UM" "buy(uint256,uint128,uint128)" "$LISTING_ID" "$BUY_UNITS_WEI" "$LIST_PRICE_WEI"
BUY_BLOCK="$SENT_BLOCK"
read -r L_SELLER L_MATURITY L_EXPIRY L_FEE L_LEFT L_PRICE < <(read_raw_at "$BUY_BLOCK" "$UM" "listingOf(uint256)" "$LISTING_ID" \
  | "$PY" -I -c '
import sys
raw = sys.stdin.read().strip()[2:]
w = [raw[64 * i:64 * (i + 1)] for i in range(6)]
print("0x" + w[0][24:], *(int(x, 16) for x in w[1:]))' | tr -d '\r') || true
[[ "${L_SELLER:-}" =~ ^0x[0-9a-fA-F]{40}$ && "${L_LEFT:-}" =~ ^[0-9]+$ ]] || die "could not read listing $LISTING_ID"
BUYER_UNITS="$(read_at "$BUY_BLOCK" "$CM" "balanceOf(address,uint256)(uint256)" "$BUYER" "$NOV19")"
echo "   listingOf($LISTING_ID): seller $L_SELLER, maturity $L_MATURITY, expiry $L_EXPIRY, fee $L_FEE bps, units left $(musd "$L_LEFT"), price $(musd "$L_PRICE") MUSD"
echo "   the buyer holds $(musd "$BUYER_UNITS") units of $NOV19"

echo "== Step 10: summary"
LATEST="$(cast block-number --rpc-url "$RPC")"
OWED_NOW="$(read_at "$LATEST" "$LM" "owedOf(uint256)(uint256)" "$TOKEN_ID")"
read -r LOCK_AMOUNT LOCK_END < <(read_raw_at "$LATEST" "$LM" "lockOf(uint256)" "$TOKEN_ID" | "$PY" -I -c '
import sys
raw = sys.stdin.read().strip()[2:]
print(int(raw[0:64], 16), int(raw[64:128], 16))' | tr -d '\r') || true
[[ "${LOCK_AMOUNT:-}" =~ ^[0-9]+$ ]] || die "could not read the lock of #$TOKEN_ID"
USED_WEIGHT="$(read_at "$LATEST" "$POOLS_VOTER" "usedWeights(uint256)(uint256)" "$TOKEN_ID")"
pool_votes() {
  cast call "$POOLS_VOTER" "votes(uint256,address)(uint256)" "$TOKEN_ID" "$1" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}' \
    || echo "unreadable"
}
VOTE_TIME="$(cast block "$VOTE_BLOCK" --field timestamp --rpc-url "$RPC" | awk '{print $1}')"
echo "   addresses: CreditMarkets $CM, LoanManager $LM, PayDown $PD, UnitMarket $UM, PassThrough $PT"
echo "   wallets: deployer $DEPLOYER, borrower $BORROWER, buyer $BUYER"
echo "   offers: 12 Nov parked #$(done_value OFFER_NOV12_ID), 19 Nov parked #$OFFER_19_ID, 26 Nov plain #$(done_value OFFER_NOV26_ID)"
echo "   demo position: veBTC #$TOKEN_ID, $(cast from-wei "$LOCK_AMOUNT") BTC locked until $LOCK_END, owed $(musd "$OWED_NOW") MUSD due $NOV19"
echo "   votes: usedWeights $USED_WEIGHT; MUSD/mT $(pool_votes "$POOL_MUSD_MT"); mcbBTC/BTC $(pool_votes "$POOL_MCBBTC_BTC"); cast at $VOTE_TIME, $(((EPOCH_END - VOTE_TIME) / 60)) minutes before the epoch ends"
echo "   reward operator: $POS_OPERATOR (PayDown)"
echo "   listing #$LISTING_ID: $(musd "$L_LEFT") units left of 5 at $(musd "$L_PRICE") MUSD; buyer holds $(musd "$BUYER_UNITS")"
echo "   transactions:"
while IFS='|' read -r label hash block gas_used; do
  echo "     $label: $hash (block $block, gas $gas_used)"
done < "$TX_LOG"
if [ -s "$SKIPPED" ]; then
  echo "   skipped:"
  while IFS='|' read -r name shown reason; do
    echo "     $name ($shown): $reason"
  done < "$SKIPPED"
fi
echo "Wave 2 live demo set up on Mezo testnet"
