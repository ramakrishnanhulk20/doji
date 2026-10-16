#!/usr/bin/env bash
# Rehearses the live testnet run on a local anvil fork of Mezo testnet, so no faucet BTC is spent finding out
# whether the broadcast path works. DeployCore and CoreSliceLive run with the real run's flags
# (--broadcast --skip-simulation --slow); only the RPC URL differs.
#
# What it does NOT prove: anvil cannot run Mezo's precompiles either, so the BTC ERC-20 precompile and the Skip
# oracle are replaced by stand-ins (MezoBtcStandIn, SkipOracleStandIn) and the oracle is never stale. Testnet
# state is frozen at the fork block, so nobody else trades, locks or posts offers during the rehearsal.
#
# Nothing here writes to the real testnet records: the anvil deployment record goes to
# deployments/anvil-rehearsal (deleted on exit), and forge's broadcast logs and cache go to scratchpad/rehearsal.
#
# Usage, from anywhere: bash packages/contracts/script/rehearse-live.sh
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CONTRACTS_DIR/../.." && pwd)"
SCRATCH_DIR="$REPO_DIR/scratchpad/rehearsal"

TESTNET_RPC="https://rpc.test.mezo.org"
ANVIL_PORT="${ANVIL_PORT:-8546}"
ANVIL_URL="http://127.0.0.1:$ANVIL_PORT"

BTC_PRECOMPILE=0x7b7C000000000000000000000000000000000000
SKIP_ORACLE=0x7b7c000000000000000000000000000000000015
PRICE_FEED=0x86bCF0841622a5dAC14A313a15f96A95421b9366
MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
VEBTC=0xB63fcCd03521Cf21907627bd7fA465C129479231
FUNDING_WEI=10000000000000000

# Must match the constants in CoreSliceLive.s.sol.
SWAP_WEI=300000000000000
LOCK_WEI=1000000000000000
BORROWER_GAS_WEI=200000000000000
SCRIPT_FLOOR_WEI=3000000000000000

die() { echo "REHEARSAL FAILED: $*" >&2; exit 1; }

# forge and anvil are native Windows programs here, so they need D:/ paths rather than /d/ paths.
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

cd "$CONTRACTS_DIR"
[ -f .env ] || die "packages/contracts/.env is missing"
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }
DEPLOYER="$(env_value DEPLOYER_ADDRESS)"
BORROWER="$(env_value BORROWER_ADDRESS)"
[ -n "$DEPLOYER" ] && [ -n "$BORROWER" ] || die "DEPLOYER_ADDRESS and BORROWER_ADDRESS must be set in .env"
PY="$(pick_python)"

mkdir -p "$SCRATCH_DIR"
export DEPLOYMENTS_DIR="deployments/anvil-rehearsal"
FOUNDRY_BROADCAST="$(native_path "$SCRATCH_DIR/broadcast")"
FOUNDRY_CACHE_PATH="$(native_path "$SCRATCH_DIR/cache")"
export FOUNDRY_BROADCAST FOUNDRY_CACHE_PATH
rm -rf "$SCRATCH_DIR/broadcast" "${CONTRACTS_DIR:?}/$DEPLOYMENTS_DIR"

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
  rm -rf "${CONTRACTS_DIR:?}/$DEPLOYMENTS_DIR"
}
trap cleanup EXIT

if cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1; then
  die "something already answers on $ANVIL_URL; stop it or set ANVIL_PORT"
fi

echo "== live BTC price from Mezo testnet"
PRICE="$(cast call "$PRICE_FEED" "fetchPrice()(uint256)" --rpc-url "$TESTNET_RPC" | awk '{print $1}')"
echo "   $PRICE (18 decimals)"
TESTNET_GAS_PRICE="$(cast gas-price --rpc-url "$TESTNET_RPC")"

echo "== starting anvil, forking $TESTNET_RPC"
anvil --fork-url "$TESTNET_RPC" --chain-id 31611 --port "$ANVIL_PORT" --gas-limit 10000000 \
  > "$SCRATCH_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  if cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1; then break; fi
  sleep 1
done
[ "$(cast chain-id --rpc-url "$ANVIL_URL" 2>/dev/null)" = "31611" ] || die "anvil did not come up on $ANVIL_URL"
# Mezo headers carry no blob-gas field, and anvil refuses calls against the forked header until it has mined
# a block of its own.
cast rpc evm_mine --rpc-url "$ANVIL_URL" >/dev/null
echo "   anvil up at block $(cast block-number --rpc-url "$ANVIL_URL")"

echo "== standing in for the BTC and Skip oracle precompiles"
# The oracle stand-in lives here, not in a script file, because forge refuses to run a script file that holds
# more than one contract. PriceFeed reads latestRoundData() and decimals(); every answer carries the current
# block time, so its 60-second staleness check always passes. Slot 0 receives the live price below.
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
BTC_CODE="$(forge inspect test/utils/MezoBtcStandIn.sol:MezoBtcStandIn deployedBytecode)"
ORACLE_CODE="$(FOUNDRY_CACHE_PATH="$(native_path "$SCRATCH_DIR/standins/cache")" \
  FOUNDRY_OUT="$(native_path "$SCRATCH_DIR/standins/out")" \
  forge inspect "$(native_path "$SCRATCH_DIR/standins/SkipOracleStandIn.sol"):SkipOracleStandIn" deployedBytecode)"
cast rpc anvil_setCode "$BTC_PRECOMPILE" "$BTC_CODE" --rpc-url "$ANVIL_URL" >/dev/null
cast rpc anvil_setCode "$SKIP_ORACLE" "$ORACLE_CODE" --rpc-url "$ANVIL_URL" >/dev/null
cast rpc anvil_setStorageAt "$SKIP_ORACLE" 0x0 "$(cast to-uint256 "$PRICE")" --rpc-url "$ANVIL_URL" >/dev/null
ANVIL_PRICE="$(cast call "$PRICE_FEED" "fetchPrice()(uint256)" --rpc-url "$ANVIL_URL" | awk '{print $1}')"
[ "$ANVIL_PRICE" = "$PRICE" ] || die "PriceFeed on anvil returned $ANVIL_PRICE, expected $PRICE"
echo "   PriceFeed on anvil answers $ANVIL_PRICE"

echo "== funding deployer and borrower with 0.01 BTC each"
for account in "$DEPLOYER" "$BORROWER"; do
  cast rpc anvil_setBalance "$account" "$(cast to-hex "$FUNDING_WEI")" --rpc-url "$ANVIL_URL" >/dev/null
done

run_script() {
  local name="$1"
  local log="$SCRATCH_DIR/$name.log"
  echo "== forge script script/$name.s.sol --rpc-url $ANVIL_URL --broadcast --skip-simulation --slow"
  if ! forge script "script/$name.s.sol" --rpc-url "$ANVIL_URL" --broadcast --skip-simulation --slow > "$log" 2>&1; then
    tail -60 "$log" >&2
    die "$name failed; full log in $log"
  fi
  sed -n '/^== Logs ==/,/^$/p' "$log" | sed '1d'
  grep -E "ONCHAIN EXECUTION COMPLETE|Transactions saved" "$log" || true
}

run_script DeployCore
run_script CoreSliceLive

TOKEN_ID="$(grep -m1 "veBTC tokenId" "$SCRATCH_DIR/CoreSliceLive.log" | awk '{print $NF}')"
[ -n "$TOKEN_ID" ] || die "could not find the veBTC tokenId in the CoreSliceLive log"

echo "== every transaction, from forge's broadcast logs"
"$PY" - "$(native_path "$SCRATCH_DIR/broadcast")" "$DEPLOYER" "$BORROWER" "$TESTNET_GAS_PRICE" \
  "$SWAP_WEI" "$LOCK_WEI" "$BORROWER_GAS_WEI" "$SCRIPT_FLOOR_WEI" <<'PYEOF'
import json
import sys
from decimal import Decimal
from pathlib import Path

root, deployer, borrower = Path(sys.argv[1]), sys.argv[2].lower(), sys.argv[3].lower()
gas_price, swap, lock, borrower_float, floor = (int(x) for x in sys.argv[4:9])
gas = {deployer: 0, borrower: 0}
count = 0
for script in ("DeployCore.s.sol", "CoreSliceLive.s.sol"):
    run = json.loads((root / script / "31611" / "run-latest.json").read_text())
    receipts = {r["transactionHash"]: r for r in run["receipts"]}
    for tx in run["transactions"]:
        receipt = receipts[tx["hash"]]
        sender = tx["transaction"]["from"].lower()
        used = int(receipt["gasUsed"], 16)
        gas[sender] = gas.get(sender, 0) + used
        if tx.get("function"):
            label = tx["function"]
        elif tx.get("transactionType", "").startswith("CREATE"):
            label = "create " + (tx.get("contractName") or "contract")
        else:
            label = f"send {Decimal(int(tx['transaction'].get('value') or '0x0', 16)) / Decimal(10**18)} BTC"
        who = "deployer" if sender == deployer else "borrower" if sender == borrower else sender
        status = "ok" if int(receipt["status"], 16) == 1 else "FAILED"
        count += 1
        print(f"   {count:2d} {who:8s} {status:6s} {tx['hash']}  {used:>9,d} gas  {label}")
        if status != "ok":
            sys.exit(f"transaction {tx['hash']} failed")

def btc(wei):
    return f"{Decimal(wei) / Decimal(10**18):.10f} BTC"

# Headroom: forge asks for 1.3x the estimated gas, and the base fee can rise before a transaction lands.
headroom_price = gas_price * 3
deployer_gas_cost = gas[deployer] * 13 // 10 * headroom_price
borrower_gas_cost = gas[borrower] * 13 // 10 * headroom_price
needed = deployer_gas_cost + swap + lock + borrower_float
print()
print(f"   gas used: deployer {gas[deployer]:,d}, borrower {gas[borrower]:,d}")
print(f"   testnet gas price now: {gas_price} wei; budgeted at 3x price and 1.3x gas")
print(f"   borrower gas {btc(borrower_gas_cost)} fits in the {btc(borrower_float)} the deployer sends it: "
      f"{'yes' if borrower_gas_cost <= borrower_float else 'NO'}")
print(f"   real run needs: deployer gas {btc(deployer_gas_cost)} + swap {btc(swap)} + lock {btc(lock)}"
      f" + borrower float {btc(borrower_float)} = {btc(needed)}")
print(f"   CoreSliceLive refuses to start below {btc(floor)}")
print(f"MINIMUM TO CLAIM INTO DEPLOYER_ADDRESS: {btc(max(needed, floor))}")
PYEOF

echo "== final state on anvil"
btc_of() { cast call "$BTC_PRECOMPILE" "balanceOf(address)(uint256)" "$1" --rpc-url "$ANVIL_URL" | awk '{print $1}'; }
musd_of() { cast call "$MUSD" "balanceOf(address)(uint256)" "$1" --rpc-url "$ANVIL_URL" | awk '{print $1}'; }
echo "   deployer BTC  $(cast from-wei "$(btc_of "$DEPLOYER")")  (started at 0.01)"
echo "   deployer MUSD $(cast from-wei "$(musd_of "$DEPLOYER")")"
echo "   borrower BTC  $(cast from-wei "$(btc_of "$BORROWER")")  (started at 0.01)"
echo "   borrower MUSD $(cast from-wei "$(musd_of "$BORROWER")")"
OWNER="$(cast call "$VEBTC" "ownerOf(uint256)(address)" "$TOKEN_ID" --rpc-url "$ANVIL_URL")"
echo "   veBTC $TOKEN_ID owner $OWNER"
if [ "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" = "$(echo "$BORROWER" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "   NFT back with the borrower: yes"
else
  die "veBTC $TOKEN_ID is not back with the borrower"
fi
echo "REHEARSAL PASSED"
