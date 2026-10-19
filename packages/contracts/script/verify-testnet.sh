#!/usr/bin/env bash
# Verifies CreditMarkets, LoanManager and then PassThrough on Mezo testnet's Blockscout explorer, reading every
# address from deployments/31611.json. Each contract is tried and reported on its own, so one failure never
# hides the others; the script exits non-zero if any of them ends unverified. Safe to run again: a contract the
# explorer already shows as verified is skipped.
#
# The constructor arguments are encoded from the deployment record plus DeployCore's settings, then compared
# byte for byte with the tail of each contract's real creation transaction. A setting changed in DeployCore
# after the deploy fails that contract here with a clear message, instead of as an opaque bytecode mismatch on
# the explorer.
#
# All three are submitted with the same --libraries link the deploy used. Solc writes the library map into every
# contract's metadata, so leaving it out would change the metadata hash at the end of the code even for
# PassThrough itself, which links nothing.
#
# If Blockscout rejects a contract, the script retries it once with the compiler version and optimizer runs
# given explicitly, then reports the explorer's answer and moves on.
#
# Usage, from anywhere: bash packages/contracts/script/verify-testnet.sh
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORD="deployments/31611.json"
RPC="https://rpc.test.mezo.org"
VERIFIER_URL="https://api.explorer.test.mezo.org/api/"
API="https://api.explorer.test.mezo.org/api/v2"
EXPLORER="https://explorer.test.mezo.org"
CHAIN_ID=31611
SOLC_VERSION="0.8.28"
OPTIMIZER_RUNS=10

# Must match the constants in DeployCore.s.sol. The creation-input check below catches any drift.
FEE_SHARE_BPS=1000
MIN_OFFER=10000000000000000000
MAX_TERM_SECONDS=2419200
UNITS_URI=""
MAX_VOTES=30
MAX_LTV_BPS=4000
LIQ_LTV_BPS=6500
MIN_LOAN=10000000000000000000
PENALTY_BPS=500
AUCTION_FLOOR_BPS=7000
AUCTION_DURATION=259200

die() { echo "VERIFY FAILED: $*" >&2; exit 1; }

pick_python() {
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import json" >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done
  die "python is needed to read the deployment record and the explorer's answers"
}

cd "$CONTRACTS_DIR"
[ -f "$RECORD" ] || die "$RECORD is missing; broadcast script/DeployCore.s.sol first"
PY="$(pick_python)"

field() { "$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$RECORD" "$1"; }

[ "$(field broadcast)" = "True" ] || die "$RECORD is a dry run record; there is nothing on chain to verify"
[ "$(field chainId)" = "$CHAIN_ID" ] || die "$RECORD is not for chain $CHAIN_ID"
DEPLOYER="$(field deployer)"
PASS_THROUGH="$(field passThrough)"
CREDIT_MARKETS="$(field creditMarkets)"
LOAN_MANAGER="$(field loanManager)"

lower() { tr '[:upper:]' '[:lower:]'; }

is_verified() {
  curl -fsS "$API/smart-contracts/$1" 2>/dev/null \
    | "$PY" -I -c 'import json,sys; print("yes" if json.load(sys.stdin).get("is_verified") is True else "no")' 2>/dev/null \
    || echo "no"
}

wait_verified() {
  for _ in $(seq 1 24); do
    [ "$(is_verified "$1")" = "yes" ] && return 0
    sleep 5
  done
  return 1
}

# Read from the explorer, not the node: the Mezo testnet node answers "tx not found" for LoanManager's
# 27 KB creation transaction even though its receipt is there.
creation_input() {
  local tx
  tx="$(curl -fsS "$API/addresses/$1" | "$PY" -I -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("creation_transaction_hash") or d.get("creation_tx_hash") or "")')"
  if [ -z "$tx" ]; then
    echo "   the explorer does not know which transaction created $1 yet" >&2
    return 1
  fi
  if [ "$(cast receipt "$tx" status --rpc-url "$RPC")" != "true" ]; then
    echo "   creation transaction $tx did not succeed" >&2
    return 1
  fi
  curl -fsS "$API/transactions/$tx" | "$PY" -I -c 'import json,sys; print(json.load(sys.stdin)["raw_input"])'
}

check_args() {
  local name="$1" address="$2" args="$3" input
  input="$(creation_input "$address" | lower)" || return 1
  case "$input" in
    *"${args#0x}")
      echo "   $name constructor arguments match its creation transaction"
      return 0
      ;;
  esac
  echo "   $name constructor arguments differ from its creation transaction; DeployCore's settings changed?" >&2
  return 1
}

# Returns non-zero instead of exiting, so the caller can carry on with the next contract.
verify() {
  local name="$1" address="$2" target="$3"
  shift 3
  if [ "$(is_verified "$address")" = "yes" ]; then
    echo "== $name already verified: $EXPLORER/address/$address"
    return 0
  fi
  echo "== verifying $name at $address"
  local common=(--chain "$CHAIN_ID" --verifier blockscout --verifier-url "$VERIFIER_URL" --watch --libraries "$LIBRARY_LINK")
  if forge verify-contract "$address" "$target" "${common[@]}" "$@" && wait_verified "$address"; then
    echo "   verified: $EXPLORER/address/$address"
    return 0
  fi
  echo "   Blockscout did not accept $name; retrying once with the compiler settings given explicitly"
  if forge verify-contract "$address" "$target" "${common[@]}" \
    --compiler-version "$SOLC_VERSION" --optimizer-runs "$OPTIMIZER_RUNS" "$@" && wait_verified "$address"; then
    echo "   verified: $EXPLORER/address/$address"
    return 0
  fi
  echo "   $name was not verified after one retry; the explorer's answer is above" >&2
  return 1
}

FAILED=()
attempt() {
  local name="$1"
  shift
  "$@" || FAILED+=("$name")
}

verify_with_args() {
  local name="$1" address="$2" target="$3" args="$4"
  check_args "$name" "$address" "$args" || return 1
  verify "$name" "$address" "$target" --constructor-args "$args"
}

CREDIT_MARKETS_ARGS="$(cast abi-encode \
  "constructor(address,address,address,address,address,address,uint16,uint128,uint32,string)" \
  "$(field musd)" "$(field btc)" "$LOAN_MANAGER" "$DEPLOYER" "$DEPLOYER" "$DEPLOYER" \
  "$FEE_SHARE_BPS" "$MIN_OFFER" "$MAX_TERM_SECONDS" "$UNITS_URI" | lower)"

SETTINGS="($DEPLOYER,$DEPLOYER,$(field feeDistributor),$(field validatorsVoter),$MAX_VOTES,$MAX_LTV_BPS,$LIQ_LTV_BPS,$MIN_LOAN,$PENALTY_BPS,$AUCTION_FLOOR_BPS,$AUCTION_DURATION)"
LOAN_MANAGER_ARGS="$(cast abi-encode \
  "constructor(address,address,address,address,address,address,uint256,(address,address,address,address,uint16,uint16,uint16,uint128,uint16,uint16,uint32))" \
  "$(field veBTC)" "$(field priceFeed)" "$(field musd)" "$(field btc)" "$(field poolsVoter)" "$CREDIT_MARKETS" \
  "$(field lockLayoutWords)" "$SETTINGS" | lower)"

LIBRARY_LINK="src/libraries/PassThrough.sol:PassThrough:$PASS_THROUGH"

attempt CreditMarkets verify_with_args CreditMarkets "$CREDIT_MARKETS" src/CreditMarkets.sol:CreditMarkets \
  "$CREDIT_MARKETS_ARGS"
attempt LoanManager verify_with_args LoanManager "$LOAN_MANAGER" src/LoanManager.sol:LoanManager "$LOAN_MANAGER_ARGS"
attempt PassThrough verify PassThrough "$PASS_THROUGH" src/libraries/PassThrough.sol:PassThrough

echo "== explorer status"
for pair in "CreditMarkets:$CREDIT_MARKETS" "LoanManager:$LOAN_MANAGER" "PassThrough:$PASS_THROUGH"; do
  echo "   ${pair%%:*} is_verified=$(is_verified "${pair#*:}")  $EXPLORER/address/${pair#*:}"
done
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "NOT VERIFIED: ${FAILED[*]}" >&2
  exit 1
fi
echo "ALL VERIFIED"
