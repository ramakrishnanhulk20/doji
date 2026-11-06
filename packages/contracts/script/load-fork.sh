#!/usr/bin/env bash
# Load check for threat model C20, C21, C48 and C81, on a local anvil fork of Mezo testnet. Fills Wave 2 with 300 plain
# offers and 300 loans from 300 wallets, 100 of the loans due Thu 12 Nov and the rest spread over the next three
# Thursdays, and names PayDown as reward operator on 50 of them. Runs the keeper's dry run, moves time past 12 Nov, runs
# it again, starts the auctions of the 100 overdue loans, runs it a third time, then times the app's full reads with
# packages/web/scripts/check-load.ts and opens the offer and auction screens with check-load-pages.mjs. Prints one
# `measure: <name> <value>` line per number and saves every log in scratchpad/l3.
#
# What it does NOT prove:
#   - The keeper runs against a dead explorer, so it uses its RPC-only path, the worst case. The normal path, where the
#     explorer lists the logs and the RPC only catches up, is not measured, and neither is the 20-calls-per-event bound.
#   - A month of full claims. 300 is what the faucet's test BTC can really fund, about a week at 40 claims a day.
#   - Harvests. The 50 positions hold no rewards, so this proves the position cap and that none was planned.
#   - Auctions being bought or settled. They are started, from a seeded wallet, and none is bought or settled.
#   - Mezo's precompiles. anvil cannot run them, so BTC and the Skip oracle are stand-ins and the oracle is never stale.
#     Testnet state is frozen at the fork block, and nobody else acts during the run.
#
# Nothing here can reach the live chain: every send goes to 127.0.0.1:8547, the script refuses any other URL, and the
# wallets have no keys because anvil impersonates them. The keeper runs dry with KEEPER_PRIVATE_KEY empty.
#
# Usage, from anywhere: bash packages/contracts/script/load-fork.sh
# LOAD_FORK_HOLD=1 keeps the fork up after the keeper runs, until scratchpad/l3/release exists, instead of running
# the app's checks. LOAD_FORK_HOLD_ON_FAIL=1 makes a failed run print what failed and keep the fork, and the dev server
# if one is up, until that same file exists, so a fault after seeding does not cost the seeded fork. MUSD_HOLDER
# overrides the testnet address impersonated to fund the offers.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CONTRACTS_DIR/../.." && pwd)"
KEEPER_DIR="$REPO_DIR/packages/keeper"
WEB_DIR="$REPO_DIR/packages/web"
LOG_DIR="$REPO_DIR/scratchpad/l3"
RELEASE_FILE="$LOG_DIR/release"

TESTNET_RPC="https://rpc.test.mezo.org"
ANVIL_PORT=8547
ALLOWED_RPC="http://127.0.0.1:$ANVIL_PORT"
export FORK_RPC_URL="${FORK_RPC_URL:-$ALLOWED_RPC}"
# Nothing listens here, so the keeper takes the path it takes when the explorer is down.
DEAD_EXPLORER="http://127.0.0.1:8599/api"
RECORDS="../contracts/deployments/31611.json,../contracts/deployments/31611-wave2.json"

SKIP_ORACLE=0x7b7c000000000000000000000000000000000015
# An externally owned account holding about 38 million testnet MUSD on 2026-11-06, per the node.
MUSD_HOLDER="${MUSD_HOLDER:-0x401d68969c9afAdeEc0e9fE6B67221247CFa642F}"
NOV12=1794441600
HOLDER_GAS_WEI=0xde0b6b3a7640000
# Port 3002 is the owner's own dev server, so the page check brings its own.
DEV_PORT=3005
DEV_BASE="http://localhost:$DEV_PORT"
DEV_DIST=".next-l3dev"

die() { echo "LOAD CHECK FAILED: $*" >&2; exit 1; }
first_word() { awk '{print $1}' | tr -d '\r'; }

# The one gate every send and keeper run passes through.
[ "$FORK_RPC_URL" = "$ALLOWED_RPC" ] || die "FORK_RPC_URL must be $ALLOWED_RPC, got $FORK_RPC_URL"

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
  die "python is needed to seed the fork and read the keeper's logs"
}

cd "$CONTRACTS_DIR"
PY="$(pick_python)"
mkdir -p "$LOG_DIR/standins"
rm -f "$RELEASE_FILE"

record_value() {
  "$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" deployments/31611-wave2.json "$1" | tr -d '\r'
}
LOAN_MANAGER="$(record_value loanManager)"
CREDIT_MARKETS="$(record_value creditMarkets)"
PAY_DOWN="$(record_value payDown)"
MUSD="$(record_value musd)"
BTC="$(record_value btc)"
PRICE_FEED="$(record_value priceFeed)"

DEV_PID=""
stop_dev_server() {
  [ -n "$DEV_PID" ] || return 0
  local winpid=""
  [ -r "/proc/$DEV_PID/winpid" ] && winpid="$(cat "/proc/$DEV_PID/winpid")"
  # next dev runs its server in a child process, so the whole tree goes.
  [ -n "$winpid" ] && { taskkill //F //T //PID "$winpid" >/dev/null 2>&1 || true; }
  kill "$DEV_PID" 2>/dev/null || true
  wait "$DEV_PID" 2>/dev/null || true
  DEV_PID=""
  # Windows can hold a file for a moment after its process ends.
  for _ in $(seq 1 15); do
    rm -rf "${WEB_DIR:?}/$DEV_DIST" 2>/dev/null || true
    [ ! -e "$WEB_DIR/$DEV_DIST" ] && break
    sleep 2
  done
  [ ! -e "$WEB_DIR/$DEV_DIST" ] || echo "warning: $WEB_DIR/$DEV_DIST is still there" >&2
  # next dev writes its dist folder into both of these. Only that is undone, because another build may be writing them too.
  if grep -q "$DEV_DIST" "$WEB_DIR/tsconfig.json"; then
    "$PY" - "$(native_path "$WEB_DIR/tsconfig.json")" "$DEV_DIST" <<'PYEOF'
import json
import sys

path, dist = sys.argv[1:3]
config = json.load(open(path, encoding="utf-8"))
config["include"] = [item for item in config["include"] if dist not in item]
open(path, "w", encoding="utf-8", newline="\n").write(json.dumps(config, indent=2) + "\n")
PYEOF
  fi
  if grep -q "$DEV_DIST" "$WEB_DIR/next-env.d.ts"; then cp "$LOG_DIR/standins/next-env.before" "$WEB_DIR/next-env.d.ts"; fi
  if curl -s -m 3 -o /dev/null "$DEV_BASE"; then echo "warning: $DEV_BASE still answers" >&2; else echo "dev server stopped"; fi
}

ANVIL_PID=""
cleanup() {
  local code=$?
  # Here and not in die, because `set -e` ends the run without die on a failed pipeline or a failed cast.
  if [ "$code" -ne 0 ] && [ "${LOAD_FORK_HOLD_ON_FAIL:-0}" = "1" ] && [ -n "$ANVIL_PID" ] &&
    cast chain-id --rpc-url "$FORK_RPC_URL" >/dev/null 2>&1; then
    echo "run stopped with exit $code; fork held at $FORK_RPC_URL; holding until $RELEASE_FILE exists" >&2
    until [ -e "$RELEASE_FILE" ]; do sleep 2; done
  fi
  stop_dev_server
  if [ -n "$ANVIL_PID" ]; then
    local winpid=""
    [ -r "/proc/$ANVIL_PID/winpid" ] && winpid="$(cat "/proc/$ANVIL_PID/winpid")"
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
    if cast chain-id --rpc-url "$FORK_RPC_URL" >/dev/null 2>&1 && [ -n "$winpid" ]; then
      taskkill //F //PID "$winpid" >/dev/null 2>&1 || true
    fi
    if cast chain-id --rpc-url "$FORK_RPC_URL" >/dev/null 2>&1; then
      echo "warning: anvil still answers on $FORK_RPC_URL" >&2
    else
      echo "anvil stopped"
    fi
  fi
}
trap cleanup EXIT

if cast chain-id --rpc-url "$FORK_RPC_URL" >/dev/null 2>&1; then
  die "something already answers on $FORK_RPC_URL; stop it first"
fi
if curl -s -m 3 -o /dev/null "$DEAD_EXPLORER"; then
  die "something answers on $DEAD_EXPLORER, so the keeper would not take its explorer-down path"
fi
# Checked here and not at the end, so a missing tool cannot cost a full seeding.
if curl -s -m 3 -o /dev/null "$DEV_BASE"; then
  die "something answers on $DEV_BASE, and the page check needs that port for its own dev server"
fi
CHROME_PATH="${CHROME_PATH:-C:/Program Files/Google/Chrome/Application/chrome.exe}"
PUPPETEER_HOME="${PUPPETEER_HOME:-$(native_path "$REPO_DIR/scratchpad/walk")}"
export CHROME_PATH PUPPETEER_HOME
[ -f "$CHROME_PATH" ] || die "no Chrome at $CHROME_PATH; set CHROME_PATH"
[ -d "$PUPPETEER_HOME/node_modules/puppeteer-core" ] || die "no puppeteer-core under $PUPPETEER_HOME; set PUPPETEER_HOME"

echo "== live BTC price from Mezo testnet"
PRICE="$(cast call "$PRICE_FEED" "fetchPrice()(uint256)" --rpc-url "$TESTNET_RPC" | first_word)"
echo "   $PRICE (18 decimals)"

echo "== starting anvil, forking $TESTNET_RPC"
anvil --fork-url "$TESTNET_RPC" --hardfork cancun --port "$ANVIL_PORT" --gas-limit 10000000 --auto-impersonate \
  > "$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  if cast chain-id --rpc-url "$FORK_RPC_URL" >/dev/null 2>&1; then break; fi
  sleep 1
done
[ "$(cast chain-id --rpc-url "$FORK_RPC_URL" 2>/dev/null)" = "31611" ] || die "anvil did not come up on $FORK_RPC_URL"
case "$(cast client --rpc-url "$FORK_RPC_URL")" in
  *anvil*) ;;
  *) die "$FORK_RPC_URL is not anvil" ;;
esac
# Mezo headers carry no blob-gas field, and anvil refuses calls against the forked header until it has mined a block
# of its own.
cast rpc evm_mine --rpc-url "$FORK_RPC_URL" >/dev/null
FORK_BLOCK="$(cast block-number --rpc-url "$FORK_RPC_URL")"
echo "measure: fork_block $FORK_BLOCK"

echo "== standing in for the BTC and Skip oracle precompiles"
# The oracle stand-in lives here, not in a script file, because forge refuses to run a script file that holds more
# than one contract. PriceFeed reads latestRoundData() and decimals(); every answer carries the current block time, so
# its 60-second staleness check always passes, including after the time jump. Slot 0 receives the live price below.
cat > "$LOG_DIR/standins/SkipOracleStandIn.sol" <<'SOLEOF'
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
FOUNDRY_CACHE_PATH="$(native_path "$LOG_DIR/standins/cache")"
FOUNDRY_OUT="$(native_path "$LOG_DIR/standins/out")"
export FOUNDRY_CACHE_PATH FOUNDRY_OUT
BTC_CODE="$(forge inspect test/utils/MezoBtcStandIn.sol:MezoBtcStandIn deployedBytecode)"
ORACLE_CODE="$(forge inspect "$(native_path "$LOG_DIR/standins/SkipOracleStandIn.sol"):SkipOracleStandIn" deployedBytecode)"
cast rpc anvil_setCode "$BTC" "$BTC_CODE" --rpc-url "$FORK_RPC_URL" >/dev/null
cast rpc anvil_setCode "$SKIP_ORACLE" "$ORACLE_CODE" --rpc-url "$FORK_RPC_URL" >/dev/null
cast rpc anvil_setStorageAt "$SKIP_ORACLE" 0x0 "$(cast to-uint256 "$PRICE")" --rpc-url "$FORK_RPC_URL" >/dev/null
ANVIL_PRICE="$(cast call "$PRICE_FEED" "fetchPrice()(uint256)" --rpc-url "$FORK_RPC_URL" | first_word)"
[ "$ANVIL_PRICE" = "$PRICE" ] || die "PriceFeed on anvil returned $ANVIL_PRICE, expected $PRICE"
echo "   PriceFeed on anvil answers $ANVIL_PRICE"

echo "== funding wallets, posting offers, opening loans, naming PayDown"
SEED_FILE="$(native_path "$LOG_DIR/seed.json")"
export LOAN_MANAGER CREDIT_MARKETS PAY_DOWN MUSD BTC MUSD_HOLDER HOLDER_GAS_WEI SEED_FILE ALLOWED_RPC
SEL_TRANSFER="$(cast sig "transfer(address,uint256)")"
SEL_APPROVE="$(cast sig "approve(address,uint256)")"
SEL_POST="$(cast sig "postOffer(uint64,uint16,uint128)")"
SEL_BORROW="$(cast sig "lockAndBorrow(uint256,uint256,uint64,uint256[],uint128[],uint16)")"
SEL_OPERATOR="$(cast sig "setRewardOperator(uint256,address)")"
SEL_OVERDUE="$(cast sig "isOverdue(uint256)")"
SEL_START_AUCTION="$(cast sig "startAuction(uint256)")"
TOPIC_POSTED="$(cast keccak "OfferPosted(uint256,address,uint64,uint16,uint128)")"
TOPIC_BORROWED="$(cast keccak "Borrowed(uint256,address,uint64,uint256,uint256)")"
export SEL_TRANSFER SEL_APPROVE SEL_POST SEL_BORROW SEL_OPERATOR SEL_OVERDUE SEL_START_AUCTION TOPIC_POSTED TOPIC_BORROWED NOV12

# Seeding and the auctions import this one send path, so both keep the same RPC gate and the same retry.
cat > "$LOG_DIR/standins/fork_send.py" <<'PYEOF'
import http.client
import json
import os
import sys
import time
from urllib.parse import urlparse

url = os.environ["FORK_RPC_URL"]
if url != os.environ["ALLOWED_RPC"]:
    sys.exit(f"refusing to send: {url} is not {os.environ['ALLOWED_RPC']}")

parsed = urlparse(url)
conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=180)
request_id = 0


def rpc(method, *params):
    global request_id
    request_id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": list(params)})
    conn.request("POST", "/", body, {"content-type": "application/json"})
    reply = json.loads(conn.getresponse().read())
    if "error" in reply:
        raise RuntimeError(f"{method}: {str(reply['error'])[:500]}")
    return reply["result"]


if "anvil" not in rpc("web3_clientVersion").lower():
    sys.exit("refusing to send: the node is not anvil")


def word(value):
    return f"{value:064x}"


def address_word(address):
    return address[2:].lower().rjust(64, "0")


gas_used = {}


# anvil passes what it does not hold to the testnet node, and that node's faults come back through it. On 2026-11-06 a
# lookup of a pending transaction answered "method handler crashed", and another a gateway's 502 page as a Fork Error,
# with the transaction still unmined both times. Only those answers are retried, so a real fault still stops the run,
# and the wait is capped so an outage cannot hold it forever.
TESTNET_FAULTS = ("method handler crashed", "Fork Error")
TESTNET_WAIT_SECONDS = 600


def through_testnet(method, *params):
    deadline = time.time() + TESTNET_WAIT_SECONDS
    while True:
        try:
            return rpc(method, *params)
        except RuntimeError as err:
            if time.time() > deadline or not any(fault in str(err) for fault in TESTNET_FAULTS):
                raise
            time.sleep(2)


def receipt_of(tx_hash):
    for _ in range(1200):
        receipt = through_testnet("eth_getTransactionReceipt", tx_hash)
        if receipt is not None:
            return receipt
        time.sleep(0.1)
    sys.exit(f"no receipt for {tx_hash} after two minutes")


def send(kind, sender, to, data, gas):
    tx = {"from": sender, "to": to, "data": data, "gas": hex(gas)}
    tx_hash = through_testnet("eth_sendTransaction", tx)
    receipt = receipt_of(tx_hash)
    if int(receipt["status"], 16) != 1:
        try:
            rpc("eth_call", tx, hex(int(receipt["blockNumber"], 16) - 1))
            why = "the replay did not revert"
        except RuntimeError as err:
            why = str(err)
        sys.exit(f"{kind} from {sender} reverted in {tx_hash}: {why}")
    gas_used.setdefault(kind, []).append(int(receipt["gasUsed"], 16))
    return receipt
PYEOF
PYTHONPATH="$(native_path "$LOG_DIR/standins")"
export PYTHONPATH

"$PY" -u - <<'PYEOF' 2>&1 | tee "$LOG_DIR/seed.log"
import hashlib
import json
import os
import sys
import time

from fork_send import address_word, gas_used, rpc, send, word

env = os.environ

SEED = "doji-load-fork-l2"
SPREAD = [(1794441600, 100), (1795046400, 67), (1795651200, 67), (1796256000, 66)]
MUSD_WEI = 25 * 10**18
OFFER_WEI = 25 * 10**18
# The minimum loan, so each 25 MUSD offer keeps 15 MUSD open after its fill and the book really holds 300 open offers.
LOAN_WEI = 10 * 10**18
# One faucet kit's BTC.
LOCK_WEI = 10**15
# The longest term, so a lock reaches the last open Thursday.
LOCK_SECONDS = 2419200
FUNDING_WEI = 10**16
OPERATORS = 50
GAS_SIMPLE = 200_000
GAS_POST = 500_000
GAS_LOCK_BORROW = 2_500_000


# Addresses only: anvil impersonates them, so no key exists to leak.
def wallet(index):
    return "0x" + hashlib.sha256(f"{SEED}:{index}".encode()).hexdigest()[-40:]


def indexed_id(receipt, emitter, topic):
    for log in receipt["logs"]:
        if log["address"].lower() == emitter.lower() and log["topics"][0] == topic:
            return int(log["topics"][1], 16)
    sys.exit(f"no {topic} log from {emitter} in {receipt['transactionHash']}")


lm, cm, pay_down = env["LOAN_MANAGER"], env["CREDIT_MARKETS"], env["PAY_DOWN"]
musd, btc, holder = env["MUSD"], env["BTC"], env["MUSD_HOLDER"]
total = sum(count for _, count in SPREAD)
wallets = [wallet(i) for i in range(total)]
started = time.time()

rpc("anvil_setBalance", holder, env["HOLDER_GAS_WEI"])
for account in wallets:
    rpc("anvil_setBalance", account, hex(FUNDING_WEI))
for account in wallets:
    send("transfer", holder, musd, env["SEL_TRANSFER"] + address_word(account) + word(MUSD_WEI), GAS_SIMPLE)
print(f"   {total} wallets funded with 0.01 BTC and 25 MUSD")

offers = []
first = 0
for maturity, count in SPREAD:
    for at in range(count):
        maker = wallets[first + at]
        apr = 500 + (at % 4) * 50
        send("approve", maker, musd, env["SEL_APPROVE"] + address_word(cm) + word(OFFER_WEI), GAS_SIMPLE)
        receipt = send("postOffer", maker, cm, env["SEL_POST"] + word(maturity) + word(apr) + word(OFFER_WEI), GAS_POST)
        offers.append({"id": indexed_id(receipt, cm, env["TOPIC_POSTED"]), "maker": maker, "maturity": maturity, "aprBps": apr})
    first += count
    print(f"   offers posted to {first} of {total}", flush=True)

loans = []
first = 0
for maturity, count in SPREAD:
    for at in range(count):
        borrower = wallets[first + at]
        # The next wallet's offer on the same date, so nobody fills their own.
        offer = offers[first + (at + 1) % count]
        head = word(LOCK_WEI) + word(LOCK_SECONDS) + word(maturity) + word(192) + word(256) + word(offer["aprBps"])
        arrays = word(1) + word(offer["id"]) + word(1) + word(LOAN_WEI)
        send("approve", borrower, btc, env["SEL_APPROVE"] + address_word(lm) + word(LOCK_WEI), GAS_SIMPLE)
        receipt = send("lockAndBorrow", borrower, lm, env["SEL_BORROW"] + head + arrays, GAS_LOCK_BORROW)
        token = indexed_id(receipt, lm, env["TOPIC_BORROWED"])
        loans.append({"tokenId": token, "borrower": borrower, "maturity": maturity})
    first += count
    print(f"   loans opened to {first} of {total}", flush=True)

# The latest date, so these positions stay active after the time jump.
named = loans[-OPERATORS:]
for loan in named:
    data = env["SEL_OPERATOR"] + word(loan["tokenId"]) + address_word(pay_down)
    send("setRewardOperator", loan["borrower"], lm, data, GAS_SIMPLE)

with open(env["SEED_FILE"], "w", encoding="utf-8") as out:
    json.dump({"wallets": wallets, "offers": offers, "loans": loans, "operators": [l["tokenId"] for l in named]}, out, indent=1)

print(f"measure: seed_seconds {time.time() - started:.1f}")
print(f"measure: seeded_wallets {len(set(wallets))}")
print(f"measure: seeded_offers {len(offers)}")
print(f"measure: seeded_loans {len(loans)}")
for maturity, count in SPREAD:
    day = time.strftime("%Y-%m-%d", time.gmtime(maturity))
    print(f"measure: seeded_loans_{day} {sum(1 for l in loans if l['maturity'] == maturity)}")
print(f"measure: seeded_paydown_operators {len(named)}")
for kind in ("postOffer", "lockAndBorrow", "setRewardOperator"):
    print(f"measure: gas_{kind} {sum(gas_used[kind]) // len(gas_used[kind])}")
PYEOF
[ "${PIPESTATUS[0]}" -eq 0 ] || die "seeding stopped; see $LOG_DIR/seed.log"

# Reads the saved log, so the numbers come from what the keeper printed and not from a second reading of the chain.
print_keeper_measures() {
  "$PY" - "$1" "$(native_path "$2")" "$3" "$4" <<'PYEOF'
import re
import sys

name, path, seconds, code = sys.argv[1:5]
lines = open(path, encoding="utf-8", errors="replace").read().splitlines()


def out(key, value):
    print(f"measure: keeper_{name}_{key} {value}")


resolution = [i for i, l in enumerate(lines) if re.search(r"\s(loan \d+|market \d{4}-\d\d-\d\d)\s", l)]
harvest = [i for i, l in enumerate(lines) if re.search(r"\sharvest[\s:]", l)]
planned = [l for l in lines if " startAuction " in l and l.rstrip().endswith("| simulated")]
refused = [l for l in lines if "simulation failed" in l]
bound = [int(m.group(1)) for l in lines if (m := re.search(r"warning: (\d+) open loans wait for a later pass", l))]
scans = [(int(m.group(1)), int(m.group(2))) for l in lines if (m := re.search(r"; (\d+) open loans of (\d+) positions", l))]
pages = [int(m.group(1)) for l in lines if (m := re.search(r"scanned the last (\d+) pages by RPC", l))]
read = [(m.group(1), m.group(2)) for l in lines if (m := re.search(r"harvest: reading (\d+) of (\d+) positions", l))]
named = [int(m.group(1)) for l in lines if (m := re.search(r"(\d+) position\(s\) name PayDown", l))]
done = [l for l in lines if l.startswith("done:")]
left = re.search(r"left for the next run: (\d+) loans, (\d+) of them past their date, and (\d+) dates", done[-1]) if done else None

out("seconds", seconds)
out("exit", code)
out("open_loans_per_pair", ",".join(str(open_loans) for open_loans, _ in scans))
out("past_read_bound", sum(bound))
out("completeness_shortfalls", sum("loans are being missed" in l for l in lines))
out("rpc_pages_most", max(pages, default=0))
out("stopped_at_max_actions", "yes" if any("stopped resolution after MAX_ACTIONS" in l for l in lines) else "no")
out("left_next_run", left.group(1) if left else "none")
out("left_past_date", left.group(2) if left else "none")
out("left_dates", left.group(3) if left else "none")
out("planned_startAuction", len(planned))
out("first_planned", re.search(r"loan (\d+)", planned[0]).group(1) if planned else "none")
out("last_planned", re.search(r"loan (\d+)", planned[-1]).group(1) if planned else "none")
out("refused_in_simulation", len(refused))
out("harvest_named_positions", ",".join(map(str, named)) or "0")
out("harvest_read", ",".join(f"{a}_of_{b}" for a, b in read) or "none")
skips = [l.split("harvest skipped:")[1].split("|")[0].strip() for l in lines if "harvest skipped:" in l and "no PayDown in this record" not in l]
out("harvest_skip_reason", skips[0].replace(" ", "_") if skips else "none")
out("harvests_planned", sum(1 for l in lines if " harvest " in l and l.rstrip().endswith("| simulated")))
if resolution and harvest:
    out("resolution_before_harvest", "yes" if resolution[-1] < harvest[0] else "NO")
else:
    out("resolution_before_harvest", "no_harvest_lines" if resolution else "no_resolution_lines")
print(f"   {done[-1] if done else 'no summary line in the log'}")
PYEOF
}

run_keeper() {
  local name="$1"
  local log="$LOG_DIR/keeper-$name.log"
  local started ended code seconds
  [ "$FORK_RPC_URL" = "$ALLOWED_RPC" ] || die "refusing to run the keeper on $FORK_RPC_URL"
  echo "== keeper dry run: $name"
  started="$(date +%s%3N)"
  set +e
  (
    cd "$KEEPER_DIR" &&
      MEZO_TESTNET_RPC="$FORK_RPC_URL" MEZO_TESTNET_EXPLORER_API="$DEAD_EXPLORER" KEEPER_PRIVATE_KEY="" \
        DEPLOYMENT_FILES="$RECORDS" npm run keeper:dry
  ) > "$log" 2>&1
  code=$?
  set -e
  ended="$(date +%s%3N)"
  seconds="$(awk -v a="$started" -v b="$ended" 'BEGIN { printf "%.1f", (b - a) / 1000 }')"
  # The log is saved, so a line it cannot parse must not cost the seeded fork.
  print_keeper_measures "$name" "$log" "$seconds" "$code" || echo "warning: could not read the numbers out of $log"
}

run_keeper before_due

echo "== moving time past 12 Nov 00:00 UTC"
NOW="$(cast block latest --field timestamp --rpc-url "$FORK_RPC_URL" | first_word)"
cast rpc anvil_increaseTime "$((NOV12 + 3600 - NOW))" --rpc-url "$FORK_RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$FORK_RPC_URL" >/dev/null
echo "measure: fork_time_after_jump $(cast block latest --field timestamp --rpc-url "$FORK_RPC_URL" | first_word)"

"$PY" -u - <<'PYEOF'
import json
import os

from fork_send import through_testnet

loans = json.load(open(os.environ["SEED_FILE"], encoding="utf-8"))["loans"]
overdue = 0
for loan in loans:
    data = os.environ["SEL_OVERDUE"] + f"{loan['tokenId']:064x}"
    overdue += int(through_testnet("eth_call", {"to": os.environ["LOAN_MANAGER"], "data": data}, "latest"), 16)
print(f"measure: seeded_loans_overdue {overdue}")
PYEOF

run_keeper overdue

echo "== starting the auctions of the loans due 12 Nov"
if ! "$PY" -u - <<'PYEOF' 2>&1 | tee "$LOG_DIR/auctions.log"; then
import json
import os
import sys

from fork_send import gas_used, rpc, send, word

env = os.environ
# Twice the 119,000 the keeper's gas table gives, so a cold read on the fork cannot run a call out of gas.
GAS_START_AUCTION = 250_000

seed = json.load(open(env["SEED_FILE"], encoding="utf-8"))
due = [loan for loan in seed["loans"] if loan["maturity"] == int(env["NOV12"])]
if not due:
    sys.exit("no seeded loan is due 12 Nov")
# Anyone may start an auction, so one wallet starts them all. At the fork's 1 gwei a seeded wallet's 0.01 BTC runs out
# after 76 starts, so this one is topped up first.
caller = seed["wallets"][-1]
rpc("anvil_setBalance", caller, hex(10**18))
for loan in due:
    send("startAuction", caller, env["LOAN_MANAGER"], env["SEL_START_AUCTION"] + word(loan["tokenId"]), GAS_START_AUCTION)

print(f"measure: auctions_started {len(gas_used['startAuction'])}")
print(f"measure: gas_startAuction {sum(gas_used['startAuction']) // len(gas_used['startAuction'])}")
PYEOF
  die "starting the auctions stopped; see $LOG_DIR/auctions.log"
fi

run_keeper auctions_open

if [ "${LOAD_FORK_HOLD:-0}" = "1" ]; then
  echo "fork ready at $FORK_RPC_URL; holding until $RELEASE_FILE exists"
  until [ -e "$RELEASE_FILE" ]; do sleep 2; done
  exit 0
fi

echo "== the app's full reads on the fork"
if ! (cd "$WEB_DIR" && npx tsx scripts/check-load.ts) 2>&1 | tee "$LOG_DIR/web.log"; then
  die "check-load.ts failed; see $LOG_DIR/web.log"
fi

echo "== the offer and auction screens on the fork"
# Other work on this machine borrows this port for minutes at a time, and a seeded fork is too dear to lose to that.
for _ in $(seq 1 300); do
  if ! curl -s -m 2 -o /dev/null "$DEV_BASE"; then break; fi
  sleep 2
done
if curl -s -m 2 -o /dev/null "$DEV_BASE"; then die "something still answers on $DEV_BASE, so the page check has no port"; fi
cp "$WEB_DIR/next-env.d.ts" "$LOG_DIR/standins/next-env.before"
# Next loads .env.local by itself but leaves alone a name already in the environment, so an empty value keeps every
# secret out of the server. NEXT_PUBLIC_ names other than the dev test key are public IDs and stay.
DEV_ENV=("NEXT_DIST_DIR=$DEV_DIST" "NEXT_PUBLIC_DEV_TEST_KEY=")
while read -r name; do
  DEV_ENV+=("$name=")
done < <({ sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$WEB_DIR/.env.local" 2>/dev/null || true; compgen -e; } |
  grep -E 'KEY|SECRET' | grep -v '^NEXT_PUBLIC_' | sort -u)
start_dev_server() {
  (
    cd "$WEB_DIR"
    exec env "${DEV_ENV[@]}" node node_modules/next/dist/bin/next dev -p "$DEV_PORT"
  ) >> "$LOG_DIR/dev-server.log" 2>&1 &
  DEV_PID=$!
  for _ in $(seq 1 120); do
    if curl -s -m 2 -o /dev/null "$DEV_BASE/favicon.svg"; then break; fi
    sleep 1
  done
  curl -s -m 2 -o /dev/null "$DEV_BASE/favicon.svg" || die "the dev server did not come up; see $LOG_DIR/dev-server.log"
  kill -0 "$DEV_PID" 2>/dev/null || die "the dev server stopped after starting; see $LOG_DIR/dev-server.log"
}

# next/font asks Google for its font addresses on a fresh dist folder. On 2026-11-06 one answer was a /l/font?kit=...&skey=
# address, Turbopack cannot read a font address holding an &, so every page answered 500, and it keeps that answer in
# the folder. Only a fresh folder asks again, and six fresh asks minutes later were all fine.
: > "$LOG_DIR/dev-server.log"
PAGE_STATUS=""
for try in 1 2 3 4 5; do
  start_dev_server
  PAGE_STATUS="$(curl -s -m 180 -o /dev/null -w '%{http_code}' "$DEV_BASE/borrow" || true)"
  [ "$PAGE_STATUS" = "200" ] && break
  echo "the dev server answered $PAGE_STATUS for /borrow on try $try; trying again with a fresh dist folder"
  stop_dev_server
  sleep 30
done
[ "$PAGE_STATUS" = "200" ] || die "the dev server answered $PAGE_STATUS for /borrow on every try; see $LOG_DIR/dev-server.log"

if ! (cd "$WEB_DIR" && CHECK_BASE="$DEV_BASE" CHECK_SHOTS="$(native_path "$LOG_DIR")" npx tsx scripts/check-load-pages.mjs) 2>&1 |
  tee "$LOG_DIR/pages.log"; then
  die "check-load-pages failed; see $LOG_DIR/pages.log"
fi
stop_dev_server
echo "LOAD CHECK FINISHED"
