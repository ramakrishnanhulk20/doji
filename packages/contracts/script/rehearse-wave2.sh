#!/usr/bin/env bash
# Rehearses the Wave 2 deploy on a local anvil fork of Mezo testnet, so the real broadcast is never the first time
# it runs. DeployCore deploys PassThrough, CreditMarkets, LoanManager, PayDown and UnitMarket with the real run's
# flags (--broadcast --skip-simulation --slow --sender) under DEPLOYMENT_NAME=31611-wave2-rehearsal, signed by
# anvil's own funded default account, never a real key. Then a smoke on the fork: a 20 MUSD parked offer lands 1:1 in the
# real testnet sMUSD vault, the guardian stops parking, and UnitMarket's and PayDown's constructor settings read
# back as deployed. Prints the record, the gas of every transaction and one PASS or FAIL line per check, and exits
# non-zero on any FAIL.
#
# What it does NOT prove: anvil cannot run Mezo's precompiles, so the Skip oracle is replaced by a stand-in that
# answers the live testnet price and is never stale; money leaving the vault (pull-out, and the fill or cancel of a
# parked offer: test/fork/SavingsFork.t.sol, script/savings-slice.sh); a harvest or a unit sale; explorer
# verification (script/verify-testnet.sh); and the real run's --libraries link, so forge deploys PassThrough
# itself here. Testnet state is frozen at the fork block.
#
# Nothing here writes a real record. The record goes to deployments/31611-wave2-rehearsal.json and is deleted on
# exit, forge's broadcast logs go to scratchpad/rehearsal-wave2, and DeployCore itself refuses to write over an
# existing record and fails if deployments/31611.json changes.
#
# Usage, from anywhere: bash packages/contracts/script/rehearse-wave2.sh
# Needs no keys: the deployer is anvil's account 0 for this run only. KEEPER_ADDRESS comes from the shell or
# packages/contracts/.env, else anvil's account 1. MUSD_HOLDER overrides the testnet address impersonated to fund
# the 20 MUSD, and ANVIL_PORT the local port (default 8547).
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CONTRACTS_DIR/../.." && pwd)"
SCRATCH_DIR="$REPO_DIR/scratchpad/rehearsal-wave2"
CHAIN_ID=31611
NAME="$CHAIN_ID-wave2-rehearsal"
RECORD="deployments/$NAME.json"

TESTNET_RPC="https://rpc.test.mezo.org"
ANVIL_PORT="${ANVIL_PORT:-8547}"
ANVIL_URL="http://127.0.0.1:$ANVIL_PORT"

SKIP_ORACLE=0x7b7c000000000000000000000000000000000015
PRICE_FEED=0x86bCF0841622a5dAC14A313a15f96A95421b9366
MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
# An externally owned account holding about 38 million testnet MUSD on 2026-11-04, per the explorer's holder list.
MUSD_HOLDER="${MUSD_HOLDER:-0x401d68969c9afAdeEc0e9fE6B67221247CFa642F}"
OFFER_WEI=20000000000000000000
APR_BPS=600
WEEK=604800
HOLDER_GAS_WEI=0xde0b6b3a7640000

die() { echo "REHEARSAL FAILED: $*" >&2; exit 1; }

# forge, anvil and python are native Windows programs here, so they need D:/ paths rather than /d/ paths.
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
  die "python is needed to read anvil's accounts, the record and forge's broadcast log"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
first_word() { awk '{print $1}' | tr -d '\r'; }

cd "$CONTRACTS_DIR"
PY="$(pick_python)"
env_value() { [ -f .env ] && grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r' || true; }

mkdir -p "$SCRATCH_DIR"
FOUNDRY_BROADCAST="$(native_path "$SCRATCH_DIR/broadcast")"
export FOUNDRY_BROADCAST
# An existing FOUNDRY_CACHE_PATH or FOUNDRY_OUT is kept, so a caller's build isolation still holds.
if [ -z "${FOUNDRY_CACHE_PATH:-}" ]; then
  FOUNDRY_CACHE_PATH="$(native_path "$SCRATCH_DIR/cache")"
  export FOUNDRY_CACHE_PATH
fi
rm -rf "$SCRATCH_DIR/broadcast"
if [ -f "$RECORD" ]; then
  echo "== removing $RECORD left by an earlier rehearsal"
  rm -f "$RECORD"
fi

ANVIL_PID=""
cleanup() {
  if [ -n "$ANVIL_PID" ]; then
    local winpid=""
    [ -r "/proc/$ANVIL_PID/winpid" ] && winpid="$(cat "/proc/$ANVIL_PID/winpid")"
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
    if cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1 && [ -n "$winpid" ]; then
      taskkill //F //PID "$winpid" >/dev/null 2>&1 || true
    fi
    if cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1; then
      echo "warning: anvil still answers on $ANVIL_URL" >&2
    else
      echo "anvil stopped"
    fi
  fi
  rm -f "${CONTRACTS_DIR:?}/$RECORD"
  if [ -e "${CONTRACTS_DIR:?}/$RECORD" ]; then
    echo "warning: could not delete $RECORD" >&2
  else
    echo "no rehearsal record left: $RECORD deleted"
  fi
}
trap cleanup EXIT

if cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1; then
  die "something already answers on $ANVIL_URL; stop it or set ANVIL_PORT"
fi

echo "== live BTC price from Mezo testnet"
PRICE="$(cast call "$PRICE_FEED" "fetchPrice()(uint256)" --rpc-url "$TESTNET_RPC" | first_word)"
echo "   $PRICE (18 decimals)"

echo "== starting anvil, forking $TESTNET_RPC"
ACCOUNTS_FILE="$SCRATCH_DIR/anvil-accounts.json"
rm -f "$ACCOUNTS_FILE"
# The 10M gas limit is Mezo's own block limit, so a deployment too large for testnet fails here too.
anvil --fork-url "$TESTNET_RPC" --hardfork cancun --port "$ANVIL_PORT" --gas-limit 10000000 \
  --config-out "$(native_path "$ACCOUNTS_FILE")" > "$SCRATCH_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  if cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1; then break; fi
  sleep 1
done
[ "$(cast chain-id --rpc-url "$ANVIL_URL" 2>/dev/null)" = "$CHAIN_ID" ] || die "anvil did not come up on $ANVIL_URL"
# Mezo headers carry no blob-gas field, and anvil refuses calls against the forked header until it has mined a
# block of its own.
cast rpc evm_mine --rpc-url "$ANVIL_URL" >/dev/null
echo "   anvil up at block $(cast block-number --rpc-url "$ANVIL_URL")"

# Account 0's key is anvil's public test key, read from anvil's own output and passed to forge only.
read -r DEPLOYER SPARE_KEEPER < <("$PY" -I -c '
import json, sys
accounts = json.load(open(sys.argv[1]))["available_accounts"]
print(accounts[0], accounts[1])' "$(native_path "$ACCOUNTS_FILE")" | tr -d '\r')
DEPLOYER_KEY="$("$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_keys"][0])' \
  "$(native_path "$ACCOUNTS_FILE")" | tr -d '\r')"
[[ "$DEPLOYER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "could not read anvil's account 0"
[ "$(lower "$(cast wallet address --private-key "$DEPLOYER_KEY")")" = "$(lower "$DEPLOYER")" ] \
  || die "anvil's first key does not belong to its first account"
KEEPER="${KEEPER_ADDRESS:-$(env_value KEEPER_ADDRESS)}"
KEEPER="${KEEPER:-$SPARE_KEEPER}"
echo "   deployer (anvil account 0) $DEPLOYER"
echo "   keeper $KEEPER"

echo "== standing in for the Skip oracle precompile"
# The stand-in lives here, not in a script file, because forge refuses to run a script file that holds more than
# one contract. PriceFeed reads latestRoundData() and decimals(); every answer carries the current block time, so
# its 60-second staleness check always passes. Slot 0 receives the live price.
mkdir -p "$SCRATCH_DIR/standins"
cat > "$SCRATCH_DIR/standins/SkipOracleStandIn.sol" <<'SOLEOF'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract SkipOracleStandIn {
    int256 public answer;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 0);
    }
}
SOLEOF
ORACLE_CODE="$(FOUNDRY_CACHE_PATH="$(native_path "$SCRATCH_DIR/standins/cache")" \
  FOUNDRY_OUT="$(native_path "$SCRATCH_DIR/standins/out")" \
  forge inspect "$(native_path "$SCRATCH_DIR/standins/SkipOracleStandIn.sol"):SkipOracleStandIn" deployedBytecode)"
cast rpc anvil_setCode "$SKIP_ORACLE" "$ORACLE_CODE" --rpc-url "$ANVIL_URL" >/dev/null
cast rpc anvil_setStorageAt "$SKIP_ORACLE" 0x0 "$(cast to-uint256 "$PRICE")" --rpc-url "$ANVIL_URL" >/dev/null
ANVIL_PRICE="$(cast call "$PRICE_FEED" "fetchPrice()(uint256)" --rpc-url "$ANVIL_URL" | first_word)"
[ "$ANVIL_PRICE" = "$PRICE" ] || die "PriceFeed on anvil returned $ANVIL_PRICE, expected $PRICE"
echo "   PriceFeed on anvil answers $ANVIL_PRICE"

echo "== forge script script/DeployCore.s.sol --rpc-url $ANVIL_URL --broadcast --skip-simulation --slow --sender $DEPLOYER"
# Exported, so they win over anything in .env for this run only. DEPLOYMENTS_DIR is pinned so the record lands
# where the cleanup deletes it. --sender keeps forge to one pass of the script (DeployCore._checkSingleRun).
export DEPLOYMENT_NAME="$NAME" DEPLOYMENTS_DIR="deployments" DEPLOYER_ADDRESS="$DEPLOYER" KEEPER_ADDRESS="$KEEPER"
DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY"
export DEPLOYER_PRIVATE_KEY
DEPLOY_LOG="$SCRATCH_DIR/DeployCore.log"
if ! forge script script/DeployCore.s.sol --rpc-url "$ANVIL_URL" --broadcast --skip-simulation --slow \
  --sender "$DEPLOYER" > "$DEPLOY_LOG" 2>&1; then
  tail -60 "$DEPLOY_LOG" >&2
  die "DeployCore failed; full log in $DEPLOY_LOG"
fi
unset DEPLOYER_PRIVATE_KEY
sed -n '/^== Logs ==/,/^$/p' "$DEPLOY_LOG" | sed '1d;/^$/d'
grep -E "ONCHAIN EXECUTION COMPLETE|Transactions saved" "$DEPLOY_LOG" || true

[ -f "$RECORD" ] || die "DeployCore wrote no $RECORD"
echo "== the record, $RECORD"
cat "$RECORD"
echo

echo "== every deploy transaction, from forge's broadcast log"
"$PY" -I - "$(native_path "$SCRATCH_DIR/broadcast")/DeployCore.s.sol/$CHAIN_ID/run-latest.json" <<'PYEOF'
import json
import sys

run = json.load(open(sys.argv[1]))
receipts = {r["transactionHash"]: r for r in run["receipts"]}
for tx in run["transactions"]:
    receipt = receipts[tx["hash"]]
    status = "ok" if int(receipt["status"], 16) == 1 else "FAILED"
    label = tx.get("function") or ("create " + (tx.get("contractName") or "contract"))
    print(f"   {status:6s} {int(receipt['gasUsed'], 16):>10,d} gas  {label}")
    if status != "ok":
        sys.exit(f"transaction {tx['hash']} failed")
PYEOF

record() {
  "$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(native_path "$RECORD")" "$1" \
    | tr -d '\r'
}
[ "$(record broadcast)" = "True" ] || die "$RECORD is not a broadcast record"
[ "$(lower "$(record deployer)")" = "$(lower "$DEPLOYER")" ] \
  || die "the record's deployer is not anvil's account 0, so another key signed"
CM="$(record creditMarkets)"
LM="$(record loanManager)"
PD="$(record payDown)"
UM="$(record unitMarket)"
VAULT="$(record savingsVault)"
ROUTER="$(record router)"

call() { cast call "$@" --rpc-url "$ANVIL_URL" | first_word; }
# Anvil's default accounts are unlocked, so the smoke sends by address and no key appears on a command line.
send() {
  local label="$1" from="$2"
  shift 2
  local out status gas
  out="$(cast send --json --from "$from" --unlocked "$@" --rpc-url "$ANVIL_URL")" || die "$label: cast send failed"
  read -r status gas < <(printf '%s' "$out" | "$PY" -I -c '
import json, sys
r = json.load(sys.stdin)
print(int(r["status"], 16), int(r["gasUsed"], 16))' | tr -d '\r')
  [ "$status" = "1" ] || die "$label: transaction reverted"
  echo "   tx $label: ok, $gas gas"
}
equal() { [ "$(lower "$1")" = "$(lower "$2")" ]; }
difference_is() { "$PY" -I -c 'import sys; a, b, d = map(int, sys.argv[1:4]); print(1 if b - a == d else 0)' "$1" "$2" "$3" | tr -d '\r'; }
at_least() { "$PY" -I -c 'import sys; a, b = map(int, sys.argv[1:3]); print(1 if a >= b else 0)' "$1" "$2" | tr -d '\r'; }

FAILED=0
check() {
  if [ "$1" = "1" ]; then echo "PASS $2"; else echo "FAIL $2"; FAILED=$((FAILED + 1)); fi
}

echo "== funding the deployer with 20 testnet MUSD from $MUSD_HOLDER"
HOLDER_MUSD="$(call "$MUSD" "balanceOf(address)(uint256)" "$MUSD_HOLDER")"
[ "$(at_least "$HOLDER_MUSD" "$OFFER_WEI")" = "1" ] || die "$MUSD_HOLDER holds under 20 MUSD at the fork; set MUSD_HOLDER"
cast rpc anvil_setBalance "$MUSD_HOLDER" "$HOLDER_GAS_WEI" --rpc-url "$ANVIL_URL" >/dev/null
cast rpc anvil_impersonateAccount "$MUSD_HOLDER" --rpc-url "$ANVIL_URL" >/dev/null
send "MUSD.transfer(deployer, 20 MUSD) as the holder" "$MUSD_HOLDER" "$MUSD" "transfer(address,uint256)" "$DEPLOYER" "$OFFER_WEI"
cast rpc anvil_stopImpersonatingAccount "$MUSD_HOLDER" --rpc-url "$ANVIL_URL" >/dev/null

echo "== smoke 1: the deployer posts a 20 MUSD parked offer"
NOW="$(cast to-dec "$(cast block latest --field timestamp --rpc-url "$ANVIL_URL" | first_word)")"
# Two Thursdays out, so the maturity is a week boundary at least a week away and well inside the 4-week limit.
MATURITY=$(( (NOW / WEEK + 2) * WEEK ))
SHARES_BEFORE="$(call "$VAULT" "balanceOf(address)(uint256)" "$CM")"
send "MUSD.approve(CreditMarkets, 20 MUSD)" "$DEPLOYER" "$MUSD" "approve(address,uint256)" "$CM" "$OFFER_WEI"
send "CreditMarkets.postParkedOffer($MATURITY, $APR_BPS, 20 MUSD)" "$DEPLOYER" \
  "$CM" "postParkedOffer(uint64,uint16,uint128)" "$MATURITY" "$APR_BPS" "$OFFER_WEI"
SHARES_AFTER="$(call "$VAULT" "balanceOf(address)(uint256)" "$CM")"
PARKED="$(call "$CM" "parkedPrincipal()(uint256)")"
LEFT_ALLOWANCE="$(call "$MUSD" "allowance(address,address)(uint256)" "$CM" "$VAULT")"
check "$([ "$(difference_is "$SHARES_BEFORE" "$SHARES_AFTER" "$OFFER_WEI")" = "1" ] && [ "$PARKED" = "$OFFER_WEI" ] \
  && [ "$LEFT_ALLOWANCE" = "0" ] && echo 1 || echo 0)" \
  "postParkedOffer: CreditMarkets' sMUSD at $VAULT rose by exactly 20 (1:1), parkedPrincipal is $PARKED, allowance left to the vault $LEFT_ALLOWANCE"

echo "== smoke 2: the guardian stops parking"
GUARDIAN="$(call "$CM" "guardian()(address)")"
send "CreditMarkets.stopParking() as the guardian" "$GUARDIAN" "$CM" "stopParking()"
PARKING_ON="$(call "$CM" "parkingOn()(bool)")"
SHARES_STOPPED="$(call "$VAULT" "balanceOf(address)(uint256)" "$CM")"
check "$(equal "$GUARDIAN" "$DEPLOYER" && [ "$PARKING_ON" = "false" ] && [ "$SHARES_STOPPED" = "$SHARES_AFTER" ] \
  && echo 1 || echo 0)" \
  "stopParking by the guardian ($GUARDIAN): parkingOn is $PARKING_ON and the parked offer's sMUSD stays put"

echo "== smoke 3: UnitMarket's constructor settings"
UM_CM="$(call "$UM" "creditMarkets()(address)")"
UM_MUSD="$(call "$UM" "musd()(address)")"
UM_FEE="$(call "$UM" "feeBps()(uint16)")"
UM_OWNER="$(call "$UM" "owner()(address)")"
UM_GUARDIAN="$(call "$UM" "guardian()(address)")"
UM_TREASURY="$(call "$UM" "treasury()(address)")"
check "$(equal "$UM_CM" "$CM" && equal "$UM_MUSD" "$MUSD" && [ "$UM_FEE" = "$(record unitFeeBps)" ] \
  && equal "$UM_OWNER" "$DEPLOYER" && equal "$UM_GUARDIAN" "$DEPLOYER" && equal "$UM_TREASURY" "$DEPLOYER" \
  && echo 1 || echo 0)" \
  "UnitMarket: creditMarkets is the new $UM_CM, musd $UM_MUSD, fee $UM_FEE bps, owner, guardian and treasury the deployer"

echo "== smoke 4: PayDown's fixed addresses and slippage"
PD_LM="$(call "$PD" "loanManager()(address)")"
PD_ROUTER="$(call "$PD" "router()(address)")"
PD_FACTORY="$(call "$PD" "factory()(address)")"
PD_MUSD="$(call "$PD" "musd()(address)")"
PD_BTC="$(call "$PD" "btc()(address)")"
PD_FEED="$(call "$PD" "priceFeed()(address)")"
PD_SLIPPAGE="$(call "$PD" "slippageBps()(uint16)")"
ROUTER_FACTORY="$(call "$ROUTER" "defaultFactory()(address)")"
check "$(equal "$PD_LM" "$LM" && equal "$PD_ROUTER" "$ROUTER" && equal "$PD_FACTORY" "$ROUTER_FACTORY" \
  && equal "$PD_MUSD" "$MUSD" && equal "$PD_BTC" "$(record btc)" && equal "$PD_FEED" "$(record priceFeed)" \
  && [ "$PD_SLIPPAGE" = "$(record payDownSlippageBps)" ] && echo 1 || echo 0)" \
  "PayDown: loanManager is the new $PD_LM, router $PD_ROUTER, factory $PD_FACTORY, musd, btc and priceFeed the pair's, slippage $PD_SLIPPAGE bps"

if [ "$FAILED" -eq 0 ]; then
  echo "Wave 2 deploy rehearsed on an anvil fork of Mezo testnet: 4 of 4 smoke checks passed"
else
  echo "Wave 2 rehearsal NOT passed: $FAILED of 4 smoke checks failed"
  exit 1
fi
