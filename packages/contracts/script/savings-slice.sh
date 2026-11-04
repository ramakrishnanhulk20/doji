#!/usr/bin/env bash
# Proves the sMUSD parking slice with live transactions on Mezo testnet. It deploys a slice CreditMarkets and
# LoanManager wired to Mezo's real testnet sMUSD vault (script/SavingsSlice.s.sol), then with cast: the DEPLOYER
# parks a 20 MUSD offer in the vault, the BUYER deposits veBTC #410 and borrows 10 MUSD from that offer, repays the
# full debt and takes the position back. Every call is simulated from its sender before it is sent. Prints every
# transaction hash with its status, then one PASS or FAIL line per check, and exits non-zero on any FAIL.
#
# What it does NOT prove: yield booking per offer or the guardian's parking controls (the next work order), a vault
# that fails or pays short (test/unit/ParkedOffers.t.sol), or mainnet (test/fork/SavingsFork.t.sol).
#
# Cost per run: testnet gas for three deployments and nine calls, the borrow's few cents of MUSD interest from
# BUYER, and 20 test MUSD from DEPLOYER, of which 10 stays parked in the slice's open offer.
#
# Usage, from anywhere: bash packages/contracts/script/savings-slice.sh
# Reads DEPLOYER_PRIVATE_KEY, DEPLOYER_ADDRESS, BUYER_PRIVATE_KEY, BUYER_ADDRESS and MEZO_TESTNET_RPC from
# packages/contracts/.env. Keys are passed to forge and cast only, never printed.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAIN_ID=31611
EXPLORER="https://explorer.test.mezo.org"
RECORD="deployments/$CHAIN_ID-slice-savings.json"

VAULT=0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16
VEBTC=0xB63fcCd03521Cf21907627bd7fA465C129479231
MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
TOKEN_ID=410
# Thursday 12 Nov 2026 00:00 UTC; #410's lock ends Thursday 19 Nov.
MATURITY=1794441600
APR_BPS=600
OFFER_WEI=20000000000000000000
BORROW_WEI=10000000000000000000

# Gas limits sit at two to three times what the mainnet fork measured for each call; testnet gas costs well under
# a millionth of a test BTC per call, so the headroom is free.
GAS_APPROVE=150000
GAS_POST=1000000
GAS_NFT_APPROVE=200000
GAS_DEPOSIT=1000000
GAS_BORROW=1500000
GAS_REPAY=1000000
GAS_WITHDRAW=800000

# Some nodes behind the public RPC lag the others, so a read or a simulation right after a receipt is asked again
# for up to 120 s before it counts as failed.
WAIT_TRIES=40
WAIT_SECONDS=3

die() { echo "SAVINGS SLICE STOPPED: $*" >&2; exit 1; }

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
  die "python is needed to read forge's broadcast log"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

cd "$CONTRACTS_DIR"
[ -f .env ] || die "packages/contracts/.env is missing"
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }
DEPLOYER="$(env_value DEPLOYER_ADDRESS)"
BUYER="$(env_value BUYER_ADDRESS)"
DEPLOYER_KEY="$(env_value DEPLOYER_PRIVATE_KEY)"
BUYER_KEY="$(env_value BUYER_PRIVATE_KEY)"
RPC="${MEZO_TESTNET_RPC:-$(env_value MEZO_TESTNET_RPC)}"
[[ "$DEPLOYER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "DEPLOYER_ADDRESS in .env is not an address"
[[ "$BUYER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "BUYER_ADDRESS in .env is not an address"
[ -n "$DEPLOYER_KEY" ] && [ -n "$BUYER_KEY" ] || die "DEPLOYER_PRIVATE_KEY and BUYER_PRIVATE_KEY must be set in .env"
[ -n "$RPC" ] || die "MEZO_TESTNET_RPC is not set"
[ "$(lower "$(cast wallet address --private-key "$DEPLOYER_KEY")")" = "$(lower "$DEPLOYER")" ] \
  || die "DEPLOYER_PRIVATE_KEY does not belong to DEPLOYER_ADDRESS"
[ "$(lower "$(cast wallet address --private-key "$BUYER_KEY")")" = "$(lower "$BUYER")" ] \
  || die "BUYER_PRIVATE_KEY does not belong to BUYER_ADDRESS"
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || die "MEZO_TESTNET_RPC is not Mezo testnet (chain $CHAIN_ID)"
PY="$(pick_python)"

link() { echo "$EXPLORER/tx/$1"; }

# Reads a value at a pinned block, asking again while a lagging node has not reached that block yet.
read_at() {
  local block="$1"
  shift
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast call "$@" --block "$block" --rpc-url "$RPC" 2>/dev/null)"; then
      printf '%s' "$out" | awk '{print $1}'
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read $* at block $block"
}

# Simulates a call from its sender, asking again while a lagging node has not seen the previous receipt yet.
simulate() {
  local from="$1"
  shift
  local err=""
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if err="$(cast call --from "$from" "$@" --rpc-url "$RPC" 2>&1 >/dev/null)"; then
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "simulation of $2 from $from still fails after $((WAIT_TRIES * WAIT_SECONDS)) s: $err"
}

# Polls for a receipt for up to 120 s and prints its status field.
receipt_status() {
  local status=""
  for _ in $(seq 1 "$WAIT_TRIES"); do
    status="$(cast receipt --async "$1" status --rpc-url "$RPC" 2>/dev/null || true)"
    [ -n "$status" ] && { printf '%s' "$status"; return 0; }
    sleep "$WAIT_SECONDS"
  done
  return 1
}

# send <label> <key> <from> <nonce> <gas> <to> <signature> [args...]: simulates, sends with an explicit nonce and
# gas limit, waits for the receipt and sets SENT_BLOCK and SENT_HASH. A lagging node can report an old pending
# nonce, so each sender's nonce is tracked here instead of asked of the node.
SENT_BLOCK=""
SENT_HASH=""
send() {
  local label="$1" key="$2" from="$3" nonce="$4" gas="$5"
  shift 5
  simulate "$from" "$@"
  SENT_HASH="$(cast send --async --private-key "$key" --nonce "$nonce" --gas-limit "$gas" "$@" --rpc-url "$RPC")"
  [[ "$SENT_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "$label: cast send returned no transaction hash"
  local status
  status="$(receipt_status "$SENT_HASH")" || die "$label: no receipt after $((WAIT_TRIES * WAIT_SECONDS)) s for $SENT_HASH"
  case "$(lower "$(printf '%s' "$status" | awk '{print $1}')")" in
    true | 1 | 0x1) ;;
    *) die "$label failed: status $status, $(link "$SENT_HASH")" ;;
  esac
  SENT_BLOCK="$(cast receipt "$SENT_HASH" blockNumber --rpc-url "$RPC" | awk '{print $1}')"
  echo "   tx $label: ok $SENT_HASH block $SENT_BLOCK $(link "$SENT_HASH")"
}

FAILED=0
check() {
  if [ "$1" = "1" ]; then echo "PASS $2"; else echo "FAIL $2"; FAILED=$((FAILED + 1)); fi
}

holder="$(cast call "$VEBTC" "ownerOf(uint256)(address)" "$TOKEN_ID" --rpc-url "$RPC")"
[ "$(lower "$holder")" = "$(lower "$BUYER")" ] || die "veBTC #$TOKEN_ID belongs to $holder, not BUYER $BUYER"

echo "== Deploying the slice pair: forge script script/SavingsSlice.s.sol --broadcast --skip-simulation --slow"
LOG_DIR="$(mktemp -d)"
if ! forge script script/SavingsSlice.s.sol --rpc-url "$RPC" --broadcast --skip-simulation --slow > "$LOG_DIR/forge.log" 2>&1; then
  tail -40 "$LOG_DIR/forge.log" >&2
  die "the slice deploy failed; full forge log in $LOG_DIR/forge.log"
fi
sed -n '/^== Logs ==/,/^$/p' "$LOG_DIR/forge.log" | sed '1d;/^$/d'

# Prints "ok|FAILED <hash> <label>" per deploy transaction, then "next <nonce>" for the deployer.
BROADCAST_LOG="$(native_path "${FOUNDRY_BROADCAST:-$CONTRACTS_DIR/broadcast}")/SavingsSlice.s.sol/$CHAIN_ID/run-latest.json"
DEPLOY_LINES="$("$PY" -I - "$BROADCAST_LOG" "$RPC" <<'PYEOF' | tr -d '\r'
import json
import sys
import time
import urllib.request

path, rpc_url = sys.argv[1:3]
run = json.load(open(path))
receipts = {r["transactionHash"]: r for r in run["receipts"]}


def fetch_receipt(tx_hash):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getTransactionReceipt", "params": [tx_hash]})
    headers = {"content-type": "application/json", "user-agent": "doji-savings-slice"}
    for _ in range(40):
        try:
            request = urllib.request.Request(rpc_url, data=body.encode(), headers=headers)
            result = json.load(urllib.request.urlopen(request, timeout=20)).get("result")
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(3)
    return None


last_nonce = -1
for tx in run["transactions"]:
    receipt = receipts.get(tx["hash"]) or fetch_receipt(tx["hash"])
    ok = receipt is not None and int(receipt["status"], 16) == 1
    label = tx.get("function") or ("create " + (tx.get("contractName") or "contract"))
    last_nonce = max(last_nonce, int(tx["transaction"]["nonce"], 16))
    print(f"{'ok' if ok else 'FAILED'} {tx['hash']} {label.replace(' ', '_')}")
print(f"next {last_nonce + 1}")
PYEOF
)"
DEPLOYER_NONCE=""
while read -r status hash label; do
  if [ "$status" = "next" ]; then DEPLOYER_NONCE="$hash"; continue; fi
  echo "   tx ${label//_/ }: $status $hash $(link "$hash")"
  [ "$status" = "ok" ] || die "deploy transaction $hash did not succeed"
done <<< "$DEPLOY_LINES"
[[ "$DEPLOYER_NONCE" =~ ^[0-9]+$ ]] && [ "$DEPLOYER_NONCE" -gt 0 ] || die "could not read the deployer's nonce from forge's log"

[ -f "$RECORD" ] || die "forge wrote no $RECORD"
read -r CM LM < <("$PY" -I -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["broadcast"] is True; print(r["creditMarkets"], r["loanManager"])' "$(native_path "$CONTRACTS_DIR/$RECORD")" | tr -d '\r')
[[ "$CM" =~ ^0x[0-9a-fA-F]{40}$ && "$LM" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$RECORD does not name both contracts"
echo "   CreditMarkets $CM"
echo "   LoanManager   $LM"
BUYER_NONCE="$(cast nonce "$BUYER" --rpc-url "$RPC")"

echo "== The deployer parks a 20 MUSD offer in the sMUSD vault"
send "MUSD.approve(CreditMarkets, 20 MUSD)" "$DEPLOYER_KEY" "$DEPLOYER" "$DEPLOYER_NONCE" "$GAS_APPROVE" \
  "$MUSD" "approve(address,uint256)" "$CM" "$OFFER_WEI"
DEPLOYER_NONCE=$((DEPLOYER_NONCE + 1))
send "CreditMarkets.postParkedOffer($MATURITY, $APR_BPS, 20 MUSD)" "$DEPLOYER_KEY" "$DEPLOYER" "$DEPLOYER_NONCE" "$GAS_POST" \
  "$CM" "postParkedOffer(uint64,uint16,uint128)" "$MATURITY" "$APR_BPS" "$OFFER_WEI"
POST_BLOCK="$SENT_BLOCK"
POST_HASH="$SENT_HASH"
OFFER_PARKED_TOPIC="$(cast keccak "OfferParked(uint256,uint128)")"
OFFER_ID="$(cast receipt "$POST_HASH" --json --rpc-url "$RPC" | "$PY" -I -c '
import json, sys
cm, topic = sys.argv[1].lower(), sys.argv[2].lower()
for log in json.load(sys.stdin)["logs"]:
    if log["address"].lower() == cm and log["topics"][0].lower() == topic:
        print(int(log["topics"][1], 16))
        break
' "$CM" "$OFFER_PARKED_TOPIC" | tr -d '\r')"
[[ "$OFFER_ID" =~ ^[0-9]+$ ]] || die "no OfferParked event in $POST_HASH"
echo "   offer $OFFER_ID parked"
SHARES_BEFORE_POST="$(read_at $((POST_BLOCK - 1)) "$VAULT" "balanceOf(address)(uint256)" "$CM")"
SHARES_AFTER_POST="$(read_at "$POST_BLOCK" "$VAULT" "balanceOf(address)(uint256)" "$CM")"

echo "== The buyer deposits veBTC #$TOKEN_ID and borrows 10 MUSD from the parked offer"
send "veBTC.approve(LoanManager, $TOKEN_ID)" "$BUYER_KEY" "$BUYER" "$BUYER_NONCE" "$GAS_NFT_APPROVE" \
  "$VEBTC" "approve(address,uint256)" "$LM" "$TOKEN_ID"
BUYER_NONCE=$((BUYER_NONCE + 1))
send "LoanManager.deposit($TOKEN_ID)" "$BUYER_KEY" "$BUYER" "$BUYER_NONCE" "$GAS_DEPOSIT" \
  "$LM" "deposit(uint256)" "$TOKEN_ID"
BUYER_NONCE=$((BUYER_NONCE + 1))
send "LoanManager.borrow($TOKEN_ID, $MATURITY, [$OFFER_ID], [10 MUSD], $APR_BPS)" "$BUYER_KEY" "$BUYER" "$BUYER_NONCE" "$GAS_BORROW" \
  "$LM" "borrow(uint256,uint64,uint256[],uint128[],uint16)" "$TOKEN_ID" "$MATURITY" "[$OFFER_ID]" "[$BORROW_WEI]" "$APR_BPS"
BUYER_NONCE=$((BUYER_NONCE + 1))
BORROW_BLOCK="$SENT_BLOCK"
SHARES_BEFORE_BORROW="$(read_at $((BORROW_BLOCK - 1)) "$VAULT" "balanceOf(address)(uint256)" "$CM")"
SHARES_AFTER_BORROW="$(read_at "$BORROW_BLOCK" "$VAULT" "balanceOf(address)(uint256)" "$CM")"
BUYER_MUSD_BEFORE="$(read_at $((BORROW_BLOCK - 1)) "$MUSD" "balanceOf(address)(uint256)" "$BUYER")"
BUYER_MUSD_AFTER="$(read_at "$BORROW_BLOCK" "$MUSD" "balanceOf(address)(uint256)" "$BUYER")"
OWED="$(read_at "$BORROW_BLOCK" "$LM" "owedOf(uint256)(uint256)" "$TOKEN_ID")"
echo "   debt to repay: $(cast from-wei "$OWED") MUSD"

echo "== The buyer repays in full and takes the position back"
send "MUSD.approve(LoanManager, debt)" "$BUYER_KEY" "$BUYER" "$BUYER_NONCE" "$GAS_APPROVE" \
  "$MUSD" "approve(address,uint256)" "$LM" "$OWED"
BUYER_NONCE=$((BUYER_NONCE + 1))
send "LoanManager.repay($TOKEN_ID, debt)" "$BUYER_KEY" "$BUYER" "$BUYER_NONCE" "$GAS_REPAY" \
  "$LM" "repay(uint256,uint256)" "$TOKEN_ID" "$OWED"
BUYER_NONCE=$((BUYER_NONCE + 1))
send "LoanManager.withdrawCollateral($TOKEN_ID)" "$BUYER_KEY" "$BUYER" "$BUYER_NONCE" "$GAS_WITHDRAW" \
  "$LM" "withdrawCollateral(uint256)" "$TOKEN_ID"
OWNER_AFTER="$(read_at "$SENT_BLOCK" "$VEBTC" "ownerOf(uint256)(address)" "$TOKEN_ID")"

echo "== Checks"
rose_by() { "$PY" -I -c 'import sys; a, b, d = map(int, sys.argv[1:4]); print(1 if b - a == d else 0)' "$1" "$2" "$3"; }
check "$(rose_by "$SHARES_BEFORE_POST" "$SHARES_AFTER_POST" "$OFFER_WEI" | tr -d '\r')" \
  "CreditMarkets' sMUSD at the testnet vault rose by exactly 20 MUSD in the parked post (block $POST_BLOCK: $(cast from-wei "$SHARES_BEFORE_POST") to $(cast from-wei "$SHARES_AFTER_POST"))"
check "$(rose_by "$SHARES_AFTER_BORROW" "$SHARES_BEFORE_BORROW" "$BORROW_WEI" | tr -d '\r')" \
  "CreditMarkets' sMUSD fell by exactly 10 MUSD in the borrow (block $BORROW_BLOCK: $(cast from-wei "$SHARES_BEFORE_BORROW") to $(cast from-wei "$SHARES_AFTER_BORROW"))"
check "$(rose_by "$BUYER_MUSD_BEFORE" "$BUYER_MUSD_AFTER" "$BORROW_WEI" | tr -d '\r')" \
  "the buyer's MUSD rose by exactly 10 MUSD in the borrow transaction ($(cast from-wei "$BUYER_MUSD_BEFORE") to $(cast from-wei "$BUYER_MUSD_AFTER"))"
check "$([ "$(lower "$OWNER_AFTER")" = "$(lower "$BUYER")" ] && echo 1 || echo 0)" \
  "after the repay and withdrawCollateral, veBTC #$TOKEN_ID is back with the buyer ($OWNER_AFTER)"

if [ "$FAILED" -eq 0 ]; then
  echo "sMUSD parking slice proven on Mezo testnet: 4 of 4 checks passed"
else
  echo "sMUSD parking slice NOT proven: $FAILED of 4 checks failed"
  exit 1
fi
