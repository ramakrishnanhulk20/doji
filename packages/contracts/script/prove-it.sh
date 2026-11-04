#!/usr/bin/env bash
# Proves Doji's main promise against a live Mezo testnet deployment, by default the Wave 2 pair in
# deployments/31611-wave2.json, using the BORROWER wallet from packages/contracts/.env: lock 0.0005 test BTC, borrow
# the 10 MUSD minimum from the cheapest open offer at a fixed rate, check the loan on chain, attack it as a stranger
# (simulated, never sent), repay in full and take the position back. On the Wave 2 pair it also checks that a loan
# filled from an offer parked in Mezo's sMUSD vault reaches the borrower as plain MUSD, names PayDown as the
# position's reward operator, refuses a stranger who tries to name itself, and deletes the operator with the
# position. Prints one PASS, FAIL or SKIP line per check, an explorer link for every transaction it sends, and a
# final verdict that counts only the checks that ran.
#
# Cost per run: gas, a few cents of MUSD interest, and 0.0005 test BTC that stays locked in the returned veBTC
# position until the loan date; after that date the borrower can withdraw it from veBTC.
#
# What it does NOT prove: auctions, settle and redemption (the keeper and the demo loans cover those), a PayDown
# harvest, or how the contracts behave while the oracle is stale.
#
# Usage, from anywhere:
#   bash packages/contracts/script/prove-it.sh
#   DEPLOYMENT_FILE=deployments/31611.json bash packages/contracts/script/prove-it.sh
#   bash packages/contracts/script/prove-it.sh --resume <positionId> <borrowBlock>
# The second form runs the original eight checks on the 20 October pair; DEPLOYMENT_FILE is a record under
# packages/contracts/deployments. The third re-runs the checks and the repayment for a position a stopped run left
# open; the first run prints both numbers. PROVE_IT_RPC_URL points the run at another node on chain 31611, such as
# an anvil fork.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTNET_RPC="https://rpc.test.mezo.org"
RPC_URL="${PROVE_IT_RPC_URL:-$TESTNET_RPC}"
EXPLORER="https://explorer.test.mezo.org"
CHAIN_ID=31611
# Must match DEFAULT_RECORD in ProveIt.s.sol. Exported because ProveIt reads the same variable.
export DEPLOYMENT_FILE="${DEPLOYMENT_FILE:-deployments/$CHAIN_ID-wave2.json}"
RECORD="$DEPLOYMENT_FILE"
SCRIPT="script/ProveIt.s.sol:ProveIt"
# Must match MIN_BORROWER_BTC in ProveIt.s.sol: 0.0005 to lock plus room for gas.
MIN_BTC_WEI=800000000000000
BROADCAST=(--broadcast --skip-simulation --slow)

die() { echo "PROVE-IT STOPPED: $*" >&2; exit 1; }

# forge and python are native Windows programs on this machine, so they need D:/ paths rather than /d/ paths.
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
  die "python is needed to read forge's broadcast logs"
}

RESUME_ID=""
RESUME_BLOCK=""
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 3 ] && [ "$1" = "--resume" ] || die "usage: prove-it.sh [--resume <positionId> <borrowBlock>]"
  [[ "$2" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ ]] || die "--resume takes two whole numbers"
  RESUME_ID="$2"
  RESUME_BLOCK="$3"
fi

cd "$CONTRACTS_DIR"
[ -f .env ] || die "packages/contracts/.env is missing"
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }
BORROWER="$(env_value BORROWER_ADDRESS)"
[[ "$BORROWER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "BORROWER_ADDRESS in packages/contracts/.env is not an address"
PY="$(pick_python)"

# foundry.toml lets forge read only ./deployments, so any other path would fail later inside forge.
[[ "$RECORD" =~ ^deployments/[A-Za-z0-9._-]+\.json$ ]] || die "DEPLOYMENT_FILE must be a record in deployments/, such as deployments/31611.json"
[ -f "$RECORD" ] || die "$RECORD is missing; deploy first"
# A record that names PayDown is a Wave 2 pair: ProveIt.s.sol applies the same rule to the same key.
read -r IS_BROADCAST RECORD_CHAIN IS_WAVE2 < <("$PY" -I -c '
import json, sys
record = json.load(open(sys.argv[1]))
print(record.get("broadcast") is True, record.get("chainId"), "payDown" in record)
' "$(native_path "$CONTRACTS_DIR/$RECORD")" | tr -d '\r')
[ "$IS_BROADCAST" = "True" ] || die "$RECORD is not a broadcast record, so nothing it names is on chain"
[ "$RECORD_CHAIN" = "$CHAIN_ID" ] || die "$RECORD is for chain $RECORD_CHAIN, not Mezo testnet ($CHAIN_ID)"
if [ "$IS_WAVE2" = "True" ]; then
  PAIR="the Wave 2 pair"
  TOTAL_CHECKS=12
else
  PAIR="the 20 October pair"
  TOTAL_CHECKS=8
fi
[ "$(cast chain-id --rpc-url "$RPC_URL")" = "$CHAIN_ID" ] || die "$RPC_URL is not Mezo testnet (chain $CHAIN_ID)"
echo "deployment record $RECORD, $PAIR"

BROADCAST_DIR="$(native_path "${FOUNDRY_BROADCAST:-$CONTRACTS_DIR/broadcast}")/ProveIt.s.sol/$CHAIN_ID"
LOG_DIR="$(mktemp -d)"
BORROWED_TOPIC="$(cast keccak "Borrowed(uint256,address,uint64,uint256,uint256)")"

link() {
  if [ "$RPC_URL" = "$TESTNET_RPC" ]; then echo "$EXPLORER/tx/$1"; else echo "$1 (rehearsal node, no explorer)"; fi
}

# Runs one ProveIt step with forge and prints its log lines. Extra arguments go to forge.
run_step() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  rm -f "$BROADCAST_DIR/$name-latest.json"
  if ! forge script "$SCRIPT" "$@" --rpc-url "$RPC_URL" > "$log" 2>&1; then
    grep -E "^\s*(PASS|FAIL|SKIP|BORROWER|No open offer)" "$log" || true
    tail -25 "$log" >&2
    die "step $name failed; full forge log in $log"
  fi
  sed -n '/^== Logs ==/,/^$/p' "$log" | sed '1d;/^$/d'
}

# Prints every transaction a broadcast step sent, with its link, and fails on any that did not succeed. With a
# second argument, prints "<position id> <block>" of the Borrowed event in that function's receipt instead; with
# a third, prints only the block of the first receipt for that function.
read_broadcast() {
  # Windows python ends lines with a carriage return, which forge would read as part of a number.
  "$PY" -I - "$BROADCAST_DIR/$1-latest.json" "${2:-}" "${3:-}" "$BORROWED_TOPIC" "$RPC_URL" <<'PYEOF' | tr -d '\r'
import json
import sys
import time
import urllib.request

path, want, mode, borrowed_topic, rpc_url = sys.argv[1:6]
run = json.load(open(path))
receipts = {r["transactionHash"]: r for r in run["receipts"]}


def fetch_receipt(tx_hash):
    # Some of the nodes behind Mezo's public RPC answer null for a receipt the others have (2 of 6 answered on
    # 2026-10-20), and forge then leaves that receipt out of its run file, so a missing one is asked for again
    # before the transaction counts as failed.
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getTransactionReceipt", "params": [tx_hash]})
    headers = {"content-type": "application/json", "user-agent": "doji-prove-it"}
    for _ in range(15):
        try:
            request = urllib.request.Request(rpc_url, data=body.encode(), headers=headers)
            result = json.load(urllib.request.urlopen(request, timeout=20)).get("result")
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(2)
    return None


for tx in run["transactions"]:
    receipt = receipts.get(tx["hash"]) or fetch_receipt(tx["hash"])
    ok = receipt is not None and int(receipt["status"], 16) == 1
    label = tx.get("function") or tx.get("transactionType") or "transaction"
    if not want:
        print(f"{'ok' if ok else 'FAILED'} {tx['hash']} {label}")
        continue
    if not label.startswith(want + "("):
        continue
    if not ok:
        sys.exit(f"{label} did not succeed: {tx['hash']}")
    block = int(receipt["blockNumber"], 16)
    if mode == "block":
        print(block)
        sys.exit(0)
    for log in receipt["logs"]:
        if log["topics"] and log["topics"][0].lower() == borrowed_topic.lower():
            print(int(log["topics"][1], 16), block)
            sys.exit(0)
    sys.exit(f"no Borrowed event in {tx['hash']}")
sys.exit(0 if not want else f"no {want} transaction in {path}")
PYEOF
}

print_transactions() {
  local status hash label
  [ -f "$BROADCAST_DIR/$1-latest.json" ] || die "forge wrote no broadcast log for step $1"
  while read -r status hash label; do
    echo "   tx $label: $status $(link "$hash")"
    [ "$status" = "ok" ] || die "transaction $hash did not succeed"
  done < <(read_broadcast "$1")
}

wait_for_block() {
  for _ in $(seq 1 30); do
    [ "$(cast block-number --rpc-url "$RPC_URL")" -ge "$1" ] && return 0
    sleep 2
  done
  die "the node never reached block $1"
}

if [ -z "$RESUME_ID" ]; then
  BALANCE="$(cast balance "$BORROWER" --rpc-url "$RPC_URL")"
  if [ "$("$PY" -I -c 'import sys; print(int(sys.argv[1]) >= int(sys.argv[2]))' "$BALANCE" "$MIN_BTC_WEI")" != "True" ]; then
    echo "BORROWER $BORROWER holds $(cast from-wei "$BALANCE") test BTC; the proof needs at least 0.0008"
    echo "(0.0005 to lock, the rest for gas). Fund it, then run this again:"
    echo "  - claim test BTC for that address at https://faucet.test.mezo.org, or"
    echo "  - send it from the deployer, from packages/contracts:"
    echo "      set -a; source .env; set +a"
    echo "      cast send $BORROWER --value 0.001ether --private-key \"\$DEPLOYER_PRIVATE_KEY\" --rpc-url $TESTNET_RPC"
    exit 1
  fi
  echo "BORROWER $BORROWER holds $(cast from-wei "$BALANCE") test BTC"

  run_step borrow --sig "borrow()" "${BROADCAST[@]}"
  print_transactions borrow
  read -r TOKEN_ID BORROW_BLOCK < <(read_broadcast borrow lockAndBorrow)
  [ -n "${BORROW_BLOCK:-}" ] || die "could not read the new position from the borrow receipt"
  echo "   position $TOKEN_ID opened in block $BORROW_BLOCK (resume with: --resume $TOKEN_ID $BORROW_BLOCK)"
else
  TOKEN_ID="$RESUME_ID"
  BORROW_BLOCK="$RESUME_BLOCK"
  echo "resuming position $TOKEN_ID, opened in block $BORROW_BLOCK"
fi

wait_for_block "$BORROW_BLOCK"
if [ "$IS_WAVE2" = "True" ]; then
  # A resumed run names PayDown again; naming the same operator twice changes nothing.
  run_step nameOperator --sig "nameOperator(uint256,uint256)" "$TOKEN_ID" "$BORROW_BLOCK" "${BROADCAST[@]}"
  print_transactions nameOperator
  OPERATOR_BLOCK="$(read_broadcast nameOperator setRewardOperator block)"
  [ -n "$OPERATOR_BLOCK" ] || die "could not read the setRewardOperator block from the receipts"
  wait_for_block "$OPERATOR_BLOCK"
fi
run_step checkAndRepay --sig "checkAndRepay(uint256,uint256)" "$TOKEN_ID" "$BORROW_BLOCK" "${BROADCAST[@]}"
print_transactions checkAndRepay
REPAY_BLOCK="$(read_broadcast checkAndRepay repay block)"
[ -n "$REPAY_BLOCK" ] || die "could not read the repay block from the receipts"

wait_for_block "$REPAY_BLOCK"
run_step confirmReturned --sig "confirmReturned(uint256,uint256,uint256)" "$TOKEN_ID" "$BORROW_BLOCK" "$REPAY_BLOCK"

CHECK_LOGS=("$LOG_DIR/checkAndRepay.log" "$LOG_DIR/confirmReturned.log")
PASSED="$(cat "${CHECK_LOGS[@]}" | grep -cE '^\s*PASS ' || true)"
FAILED="$(cat "${CHECK_LOGS[@]}" | grep -cE '^\s*FAIL ' || true)"
SKIPPED="$(cat "${CHECK_LOGS[@]}" | grep -cE '^\s*SKIP ' || true)"
# W1 is the only check allowed to skip, and only on the Wave 2 pair; any other SKIP fails the verdict.
OTHER_SKIPS="$(cat "${CHECK_LOGS[@]}" | grep -E '^\s*SKIP ' | grep -cvE '^\s*SKIP W1 ' || true)"
EXPECTED_RAN=$((TOTAL_CHECKS - SKIPPED))
cat "${CHECK_LOGS[@]}" | sed -nE 's/^\s*SKIP (\S+) (.*)$/skipped: \1 (\2)/p'
if [ "$FAILED" -eq 0 ] && [ "$OTHER_SKIPS" -eq 0 ] && [ "$PASSED" -eq "$EXPECTED_RAN" ] \
  && { [ "$SKIPPED" -eq 0 ] || [ "$IS_WAVE2" = "True" ]; }; then
  echo "Doji promise proven: $PASSED of $PASSED checks passed"
else
  echo "Doji promise NOT proven: $PASSED of $EXPECTED_RAN checks passed, $FAILED failed, $SKIPPED skipped (logs in $LOG_DIR)"
  exit 1
fi
