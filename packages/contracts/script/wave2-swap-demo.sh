#!/usr/bin/env bash
# Opens a second Wave 2 demo loan on Mezo testnet, against the contracts in deployments/31611-wave2.json, with cast.
# The DEPLOYER sends the BORROWER 0.006 test BTC. The BORROWER locks 0.005 of it for 28 days and borrows 10 MUSD from
# offer 1 (12 Nov), then in later blocks votes the new position 100% on the MUSD/mT pool and names PayDown its reward
# operator. After the epoch ends the borrower can run harvestAndSwap on this position and sell the mT incentive for
# MUSD. Every call is simulated from its sender before it is sent. Prints every transaction's label and hash, then
# the reads that prove the position is set up: custody, operator, debt, votes and the vote's block time.
#
# What it does NOT prove: the harvest or the swap. Incentives become claimable only after the epoch ends (Thursday
# 00:00 UTC). If the vote window would close before the vote can land, the run stops before sending anything more.
#
# Safe to run again after a failure: every finished transaction is recorded in scratchpad/wave2-swap-demo/progress.env
# and skipped on the next run, so no transfer, loan or vote is sent twice. That file is tied to this deployment's
# LoanManager and CreditMarkets and refused for any other.
#
# Cost per run: 0.006 test BTC from DEPLOYER to the borrower (0.005 of it locked) and testnet gas.
#
# Usage, from anywhere: bash packages/contracts/script/wave2-swap-demo.sh
# Reads DEPLOYER_*, BORROWER_* and MEZO_TESTNET_RPC from packages/contracts/.env. Keys go to cast only and are never
# printed.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CONTRACTS_DIR/../.." && pwd)"
SCRATCH_DIR="$REPO_DIR/scratchpad/wave2-swap-demo"
PROGRESS="$SCRATCH_DIR/progress.env"
TX_LOG="$SCRATCH_DIR/transactions.txt"
CHAIN_ID=31611
EXPLORER="https://explorer.test.mezo.org"
RECORD="deployments/$CHAIN_ID-wave2.json"

BTC=0x7b7C000000000000000000000000000000000000
POOL_MUSD_MT=0x0E6BD7E52e4491320012f8C9E6161cD915BB0D19

NOV12=1794441600
OFFER_ID=1
OFFER_APR=600
# The epoch the vote must land in ends Thursday 5 Nov 00:00 UTC. PoolsVoter closes voting an hour before that.
EPOCH_END=1793836800
VOTE_WINDOW_CLOSE=$((EPOCH_END - 3600))
# Five transactions take a few minutes at most; anything closer to the vote window closing than this is refused
# rather than risk a loan that misses the epoch.
VOTE_MARGIN_SECONDS=900

BORROWER_BTC_WEI=6000000000000000
LOCK_BTC_WEI=5000000000000000
LOCK_SECONDS=2419200
BORROW_WEI=10000000000000000000
MAX_APR_BPS=600
FULL_WEIGHT=10000

# The same limits wave2-live.sh uses for the same calls: two to four times what each measured on the mainnet fork or
# the earlier testnet runs. Testnet gas is priced at a few hundred wei, so the headroom costs nothing.
GAS_APPROVE=150000
GAS_VALUE=100000
GAS_LOCK_BORROW=2500000
GAS_VOTE=2000000
GAS_OPERATOR=300000

# Some nodes behind the public RPC lag the others, so a read, a receipt or a simulation right after a receipt is
# asked again for up to 120 s before it counts as failed.
WAIT_TRIES=40
WAIT_SECONDS=3

die() { echo "WAVE 2 SWAP DEMO STOPPED: $*" >&2; exit 1; }

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
DEPLOYER_KEY="$(env_value DEPLOYER_PRIVATE_KEY)"
BORROWER_KEY="$(env_value BORROWER_PRIVATE_KEY)"
RPC="${MEZO_TESTNET_RPC:-$(env_value MEZO_TESTNET_RPC)}"
[ -n "$RPC" ] || die "MEZO_TESTNET_RPC is not set"
for who in DEPLOYER BORROWER; do
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
POOLS_VOTER="$(record poolsVoter)"
VEBTC="$(record veBTC)"
for target in "$CM" "$LM" "$PD" "$POOLS_VOTER" "$VEBTC"; do
  [[ "$target" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$RECORD names a bad address: $target"
  [ "$(cast codesize "$target" --rpc-url "$RPC")" != "0" ] || die "no code at $target"
done
[ "$(lower "$(cast call "$PD" "loanManager()(address)" --rpc-url "$RPC")")" = "$(lower "$LM")" ] \
  || die "PayDown does not point at this LoanManager"

mkdir -p "$SCRATCH_DIR"
touch "$PROGRESS" "$TX_LOG"
done_value() { grep -E "^$1=" "$PROGRESS" | tail -1 | cut -d= -f2- || true; }
mark() { echo "$1=$2" >> "$PROGRESS"; }
for tie in LOAN_MANAGER:"$LM" CREDIT_MARKETS:"$CM"; do
  tie_key="${tie%%:*}"
  tie_address="${tie#*:}"
  if [ -n "$(done_value "$tie_key")" ]; then
    [ "$(lower "$(done_value "$tie_key")")" = "$(lower "$tie_address")" ] \
      || die "$PROGRESS belongs to $tie_key $(done_value "$tie_key"), not $tie_address; move it aside first"
  else
    mark "$tie_key" "$tie_address"
  fi
done

[ "$(cast call "$CM" "isValidMaturity(uint64)(bool)" "$NOV12" --rpc-url "$RPC")" = "true" ] \
  || die "maturity $NOV12 is not open on CreditMarkets"

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

block_time() {
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast block "$1" --field timestamp --rpc-url "$RPC" 2>/dev/null)" && [ -n "$out" ]; then
      printf '%s' "$out" | head -1 | awk '{print $1}' | tr -d '\r'
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read the time of block $1"
}

# Stops the run unless the chain is still in the epoch ending EPOCH_END with time to spare before voting closes.
# PoolsVoter's own window is read so a node clock past the epoch shows up as a different window, not a late vote.
require_vote_window() {
  local latest now window
  latest="$(cast block-number --rpc-url "$RPC")"
  now="$(block_time "$latest")"
  window="$(read_at "$latest" "$POOLS_VOTER" "epochVoteEnd(uint256)(uint256)" "$now")"
  [ "$window" = "$VOTE_WINDOW_CLOSE" ] \
    || die "the chain is past the epoch ending $EPOCH_END (block $latest at $now, voting now closes at $window)"
  [ $((now + VOTE_MARGIN_SECONDS)) -lt "$VOTE_WINDOW_CLOSE" ] \
    || die "block $latest at $now is within $VOTE_MARGIN_SECONDS s of voting closing at $VOTE_WINDOW_CLOSE; not sending"
  echo "   chain time $now (block $latest), $(((VOTE_WINDOW_CLOSE - now) / 60)) minutes before voting closes"
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
# DEPLOYER or BORROWER.
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
    true | 1 | 0x1 | success) ;;
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
echo "   PoolsVoter    $POOLS_VOTER"
echo "   veBTC         $VEBTC"

if [ -z "$(done_value VOTE_HASH)" ]; then
  echo "== Vote window check"
  require_vote_window
  read -r OFFER_MATURITY OFFER_APR_NOW OFFER_LEFT OFFER_PARKED < <(read_raw_at latest "$CM" "offerOf(uint256)" "$OFFER_ID" \
    | "$PY" -I -c '
import sys
raw = sys.stdin.read().strip()[2:]
w = [int(raw[64 * i:64 * (i + 1)], 16) for i in range(5)]
print(w[1], w[2], w[3], w[4])' | tr -d '\r') || true
  [[ "${OFFER_LEFT:-}" =~ ^[0-9]+$ ]] || die "could not read offer $OFFER_ID"
  if [ -z "$(done_value LOCK_BORROW_HASH)" ]; then
    [ "$OFFER_MATURITY" = "$NOV12" ] && [ "$OFFER_APR_NOW" = "$OFFER_APR" ] && [ "$OFFER_PARKED" = "1" ] \
      || die "offer $OFFER_ID is not the parked 12 Nov offer at $OFFER_APR bps (maturity $OFFER_MATURITY, apr $OFFER_APR_NOW, parked $OFFER_PARKED)"
    "$PY" -I -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$OFFER_LEFT" "$BORROW_WEI" \
      || die "offer $OFFER_ID has only $(musd "$OFFER_LEFT") MUSD left, not 10"
  fi
  echo "   offer $OFFER_ID: maturity $OFFER_MATURITY, $OFFER_APR_NOW bps, $(musd "$OFFER_LEFT") MUSD left, parked $OFFER_PARKED"
fi

echo "== Step a: the deployer funds the borrower"
step FUND_BORROWER "send 0.006 BTC to the borrower" DEPLOYER "$GAS_VALUE" "$BORROWER" --value "$BORROWER_BTC_WEI"

echo "== Step b: the borrower approves the lock"
step APPROVE_LOCK "BTC.approve(LoanManager, 0.005 BTC)" BORROWER "$GAS_APPROVE" \
  "$BTC" "approve(address,uint256)" "$LM" "$LOCK_BTC_WEI"

echo "== Step c: the borrower locks 0.005 BTC for 28 days and borrows 10 MUSD from offer $OFFER_ID"
step LOCK_BORROW "LoanManager.lockAndBorrow(0.005 BTC, $LOCK_SECONDS s, $NOV12, [$OFFER_ID], [10 MUSD], $MAX_APR_BPS)" \
  BORROWER "$GAS_LOCK_BORROW" \
  "$LM" "lockAndBorrow(uint256,uint256,uint64,uint256[],uint128[],uint16)" \
  "$LOCK_BTC_WEI" "$LOCK_SECONDS" "$NOV12" "[$OFFER_ID]" "[$BORROW_WEI]" "$MAX_APR_BPS"
BORROW_HASH="$SENT_HASH"
BORROW_BLOCK="$SENT_BLOCK"
if [ -z "$(done_value TOKEN_ID)" ]; then
  remember TOKEN_ID event_value "$BORROW_HASH" "$LM" "Deposited(uint256,address)" 1
fi
TOKEN_ID="$(done_value TOKEN_ID)"
[[ "$TOKEN_ID" =~ ^[0-9]+$ ]] || die "no tokenId recorded for the demo position"
PRINCIPAL="$(event_value "$BORROW_HASH" "$LM" "Borrowed(uint256,address,uint64,uint256,uint256)" d0)"
EVENT_FACE="$(event_value "$BORROW_HASH" "$LM" "Borrowed(uint256,address,uint64,uint256,uint256)" d1)"
OWED_AT_BORROW="$(read_at "$BORROW_BLOCK" "$LM" "owedOf(uint256)(uint256)" "$TOKEN_ID")"
echo "   veBTC #$TOKEN_ID: principal $(musd "$PRINCIPAL") MUSD, face $(musd "$EVENT_FACE") MUSD, owed $(musd "$OWED_AT_BORROW") MUSD"

echo "== Step d: the borrower votes #$TOKEN_ID 100% on MUSD/mT, in a later block than the deposit"
if [ -z "$(done_value VOTE_HASH)" ]; then
  for _ in $(seq 1 "$WAIT_TRIES"); do
    [ "$(cast block-number --rpc-url "$RPC")" -gt "$BORROW_BLOCK" ] && break
    sleep "$WAIT_SECONDS"
  done
  [ "$(cast block-number --rpc-url "$RPC")" -gt "$BORROW_BLOCK" ] || die "no block after the deposit's $BORROW_BLOCK yet"
  require_vote_window
fi
step VOTE "LoanManager.vote($TOKEN_ID, [MUSD/mT], [$FULL_WEIGHT])" BORROWER "$GAS_VOTE" \
  "$LM" "vote(uint256,address[],uint256[])" "$TOKEN_ID" "[$POOL_MUSD_MT]" "[$FULL_WEIGHT]"
VOTE_HASH="$SENT_HASH"
VOTE_BLOCK="$SENT_BLOCK"
[ "$VOTE_BLOCK" -gt "$BORROW_BLOCK" ] || die "the vote landed in block $VOTE_BLOCK, not after the deposit's $BORROW_BLOCK"
echo "   vote in block $VOTE_BLOCK, after the deposit's block $BORROW_BLOCK"

echo "== Step e: the borrower names PayDown the reward operator of #$TOKEN_ID"
step OPERATOR "LoanManager.setRewardOperator($TOKEN_ID, PayDown)" BORROWER "$GAS_OPERATOR" \
  "$LM" "setRewardOperator(uint256,address)" "$TOKEN_ID" "$PD"
OPERATOR_HASH="$SENT_HASH"

echo "== Checks"
LATEST="$(cast block-number --rpc-url "$RPC")"
OWNER="$(read_at "$LATEST" "$VEBTC" "ownerOf(uint256)(address)" "$TOKEN_ID")"
read -r POS_BORROWER POS_OPERATOR < <(read_raw_at "$LATEST" "$LM" "positionOf(uint256)" "$TOKEN_ID" | "$PY" -I -c '
import sys
raw = sys.stdin.read().strip()[2:]
print("0x" + raw[24:64], "0x" + raw[88:128])' | tr -d '\r') || true
OWED_NOW="$(read_at "$LATEST" "$LM" "owedOf(uint256)(uint256)" "$TOKEN_ID")"
POOL_VOTES="$(read_at "$LATEST" "$POOLS_VOTER" "votes(uint256,address)(uint256)" "$TOKEN_ID" "$POOL_MUSD_MT")"
USED_WEIGHT="$(read_at "$LATEST" "$POOLS_VOTER" "usedWeights(uint256)(uint256)" "$TOKEN_ID")"
read -r LOCK_AMOUNT LOCK_END < <(read_raw_at "$LATEST" "$LM" "lockOf(uint256)" "$TOKEN_ID" | "$PY" -I -c '
import sys
raw = sys.stdin.read().strip()[2:]
print(int(raw[0:64], 16), int(raw[64:128], 16))' | tr -d '\r') || true
[[ "${LOCK_AMOUNT:-}" =~ ^[0-9]+$ ]] || die "could not read the lock of #$TOKEN_ID"
VOTE_TIME="$(block_time "$VOTE_BLOCK")"
echo "   read at block $LATEST"
echo "   veBTC ownerOf($TOKEN_ID) = $OWNER (Wave 2 LoanManager $LM)"
echo "   positionOf($TOKEN_ID): borrower $POS_BORROWER, operator $POS_OPERATOR (PayDown $PD)"
echo "   owedOf($TOKEN_ID) = $OWED_NOW ($(musd "$OWED_NOW") MUSD); at the borrow block $OWED_AT_BORROW"
echo "   PoolsVoter votes($TOKEN_ID, MUSD/mT $POOL_MUSD_MT) = $POOL_VOTES; usedWeights($TOKEN_ID) = $USED_WEIGHT"
echo "   vote block $VOTE_BLOCK at $VOTE_TIME, $(((EPOCH_END - VOTE_TIME) / 60)) minutes before the epoch ends at $EPOCH_END"
echo "   lockOf($TOKEN_ID): $(cast from-wei "$LOCK_AMOUNT") BTC until $LOCK_END"
[ "$(lower "$OWNER")" = "$(lower "$LM")" ] || die "veBTC #$TOKEN_ID is owned by $OWNER, not LoanManager $LM"
[ "$(lower "${POS_OPERATOR:-}")" = "$(lower "$PD")" ] || die "the reward operator reads ${POS_OPERATOR:-nothing}, not PayDown $PD"
[ "$(lower "${POS_BORROWER:-}")" = "$(lower "$BORROWER")" ] || die "the position's borrower reads ${POS_BORROWER:-nothing}, not $BORROWER"
[ "$POOL_VOTES" != "0" ] || die "#$TOKEN_ID has no votes on MUSD/mT"
[ "$POOL_VOTES" = "$USED_WEIGHT" ] || die "MUSD/mT votes $POOL_VOTES differ from usedWeights $USED_WEIGHT"
[ "$VOTE_TIME" -lt "$EPOCH_END" ] || die "the vote landed at $VOTE_TIME, not before the epoch ended at $EPOCH_END"
[ "$PRINCIPAL" = "$BORROW_WEI" ] || die "the loan's principal is $PRINCIPAL, not $BORROW_WEI"

echo "== Record entry for deployments/$CHAIN_ID-wave2-demo.json, loans.swap"
echo "   borrower $BORROWER, face $OWED_AT_BORROW, hash $BORROW_HASH, lockEnd $LOCK_END, maturity $NOV12,"
echo "   offerId $OFFER_ID, principal $PRINCIPAL, rewardOperator $PD, role swap, tokenId $TOKEN_ID"
echo "   transactions:"
while IFS='|' read -r label hash block gas_used; do
  echo "     $label: $hash (block $block, gas $gas_used)"
done < "$TX_LOG"
echo "   vote $VOTE_HASH, operator $OPERATOR_HASH"
echo "Wave 2 swap demo loan set up on Mezo testnet"
