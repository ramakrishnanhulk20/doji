#!/usr/bin/env bash
# Proves the starter-kit Faucet on Mezo testnet with real transactions, against deployments/31611-faucet.json. It
# reads the deployment back from the chain (C82), checks the relayer is no other wallet in .env (C65), and has the
# DEPLOYER fund the faucet with 0.0011 test BTC and 30 test MUSD and the relayer with 0.0002 test BTC. The RELAYER then
# claims one kit for a fresh random address and the script shows the kit arriving. Then it shows each refusal, every
# one simulated from its own caller and matched byte for byte against the error the contract must give: a second
# claim for that address, a stranger, a faucet too short for another kit, and a paused faucet, which is then resumed.
#
# What it does NOT prove: a hostile recipient or a smart wallet (test/unit/Faucet.t.sol), the even release through a
# day (test/unit/FaucetInvariants.t.sol), or a claim landing after a refill. The funding pays one kit and leaves the
# faucet short on purpose, so after the claim both views read 0 and the release rule cannot show a non-zero wait. The
# fresh address comes from random bytes, so no key for it exists and its kit stays where it lands.
#
# Safe to run again after a failure: every finished transaction is recorded in scratchpad/faucet-live/progress.env
# and skipped on the next run, so nothing is funded, claimed or paused twice. That file is tied to this deployment's
# Faucet and refused for any other. A finished run repeats the chain read-back and reprints what it recorded.
#
# Cost per run: 0.0013 test BTC and 30 test MUSD from DEPLOYER, of which one kit reaches the fresh address and the
# rest stays in the faucet and the relayer, plus testnet gas. It refuses to start unless DEPLOYER would keep at least
# 0.0009 test BTC for gas.
#
# Usage, from anywhere: bash packages/contracts/script/faucet-live.sh
# Reads DEPLOYER_*, RELAYER_* and MEZO_TESTNET_RPC from packages/contracts/.env. Keys go to cast only and are never
# printed.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CONTRACTS_DIR/../.." && pwd)"
SCRATCH_DIR="$REPO_DIR/scratchpad/faucet-live"
PROGRESS="$SCRATCH_DIR/progress.env"
TX_LOG="$SCRATCH_DIR/transactions.txt"
CHAIN_ID=31611
EXPLORER="https://explorer.test.mezo.org"
RECORD="deployments/$CHAIN_ID-faucet.json"

MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
ZERO_ADDRESS=0x0000000000000000000000000000000000000000

BTC_KIT_WEI=1000000000000000
MUSD_KIT_WEI=25000000000000000000
DAILY_LIMIT=40
FAUCET_BTC_WEI=1100000000000000
FAUCET_MUSD_WEI=30000000000000000000
RELAYER_BTC_WEI=200000000000000
DEPLOYER_RESERVE_WEI=900000000000000

# Two to four times what each call measured on the fork or the earlier testnet runs; testnet gas is priced at a few
# hundred wei, so the headroom costs nothing.
GAS_VALUE=100000
GAS_TRANSFER=150000
GAS_CLAIM=300000
GAS_PAUSE=100000

# Some nodes behind the public RPC lag the others, so a read, a receipt or a simulation right after a receipt is
# asked again for up to 120 s before it counts as failed.
WAIT_TRIES=40
WAIT_SECONDS=3

die() { echo "FAUCET LIVE PROOF STOPPED: $*" >&2; exit 1; }

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
shown() { cast from-wei "$1"; }

cd "$CONTRACTS_DIR"
[ -f .env ] || die "packages/contracts/.env is missing"
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }
DEPLOYER="$(env_value DEPLOYER_ADDRESS)"
RELAYER="$(env_value RELAYER_ADDRESS)"
DEPLOYER_KEY="$(env_value DEPLOYER_PRIVATE_KEY)"
RELAYER_KEY="$(env_value RELAYER_PRIVATE_KEY)"
RPC="${MEZO_TESTNET_RPC:-$(env_value MEZO_TESTNET_RPC)}"
[ -n "$RPC" ] || die "MEZO_TESTNET_RPC is not set"
for who in DEPLOYER RELAYER; do
  address="${!who}"
  key_var="${who}_KEY"
  [[ "$address" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "${who}_ADDRESS in .env is not an address"
  [ -n "${!key_var}" ] || die "${who}_PRIVATE_KEY must be set in .env"
  [ "$(lower "$(cast wallet address --private-key "${!key_var}" 2>/dev/null)")" = "$(lower "$address")" ] \
    || die "${who}_PRIVATE_KEY does not belong to ${who}_ADDRESS"
done
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || die "MEZO_TESTNET_RPC is not Mezo testnet (chain $CHAIN_ID)"
PY="$(pick_python)"

[ -f "$RECORD" ] || die "$RECORD is missing; run script/DeployFaucet.s.sol first"
record() {
  "$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(native_path "$CONTRACTS_DIR/$RECORD")" "$1" \
    | tr -d '\r'
}
[ "$(record broadcast)" = "True" ] || die "$RECORD is not a broadcast record"
[ "$(record chainId)" = "$CHAIN_ID" ] || die "$RECORD is not for chain $CHAIN_ID"
FAUCET="$(record faucet)"
[[ "$FAUCET" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$RECORD names a bad address: $FAUCET"
[ "$(lower "$(record relayer)")" = "$(lower "$RELAYER")" ] || die "$RECORD names another relayer than .env"

first_word() { printf '%s' "$1" | head -1 | awk '{print $1}'; }

# Reads the latest state, asking again while the public RPC is unavailable.
read_now() {
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast call "$@" --rpc-url "$RPC" 2>/dev/null)"; then
      first_word "$out"
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read $*"
}

# Reads a value at a pinned block, asking again while a lagging node has not reached that block yet.
read_at() {
  local block="$1"
  shift
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast call "$@" --block "$block" --rpc-url "$RPC" 2>/dev/null)"; then
      first_word "$out"
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read $* at block $block"
}

balance_at() {
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast balance "$1" --block "$2" --rpc-url "$RPC" 2>/dev/null)"; then
      printf '%s' "$out" | tr -d '\r'
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read the balance of $1 at block $2"
}

expect_read() {
  local what="$1" want="$2" got="$3"
  [ "$(lower "$got")" = "$(lower "$want")" ] || die "read-back: $what is $got, expected $want"
}

echo "== Step 1: read the deployment back from the chain (C82) and check the relayer (C65)"
[ "$(cast codesize "$FAUCET" --rpc-url "$RPC")" != "0" ] || die "no code at $FAUCET"
expect_read "musd" "$MUSD" "$(read_now "$FAUCET" "musd()(address)")"
expect_read "owner" "$DEPLOYER" "$(read_now "$FAUCET" "owner()(address)")"
expect_read "pendingOwner" "$ZERO_ADDRESS" "$(read_now "$FAUCET" "pendingOwner()(address)")"
expect_read "relayer" "$RELAYER" "$(read_now "$FAUCET" "relayer()(address)")"
expect_read "btcPerClaim" "$BTC_KIT_WEI" "$(read_now "$FAUCET" "btcPerClaim()(uint128)")"
expect_read "musdPerClaim" "$MUSD_KIT_WEI" "$(read_now "$FAUCET" "musdPerClaim()(uint128)")"
expect_read "dailyLimit" "$DAILY_LIMIT" "$(read_now "$FAUCET" "dailyLimit()(uint32)")"
[ "$BTC_KIT_WEI" -le "$(read_now "$FAUCET" "MAX_BTC_PER_CLAIM()(uint128)")" ] || die "the BTC kit is over its cap"
[ "$("$PY" -I -c 'import sys; print(int(int(sys.argv[1]) <= int(sys.argv[2])))' "$MUSD_KIT_WEI" \
  "$(read_now "$FAUCET" "MAX_MUSD_PER_CLAIM()(uint128)")" | tr -d '\r')" = "1" ] || die "the MUSD kit is over its cap"
[ "$DAILY_LIMIT" -le "$(read_now "$FAUCET" "MAX_DAILY_LIMIT()(uint32)")" ] || die "the daily limit is over its cap"
echo "   Faucet $FAUCET: code present, MUSD fixed, kit 0.001 BTC and 25 MUSD, limit $DAILY_LIMIT, all under the caps"

# DeployFaucet checks the wallet names it knows. This walks every wallet actually in .env, whatever its name, and
# reports only the variable's name.
wallets_checked=0
while IFS='=' read -r name value; do
  value="${value%$'\r'}"
  [ -n "$value" ] || continue
  case "$name" in
    RELAYER_ADDRESS | RELAYER_PRIVATE_KEY) continue ;;
    *_ADDRESS) other="$value" ;;
    *_PRIVATE_KEY) other="$(cast wallet address --private-key "$value" 2>/dev/null)" || die "$name is not a valid key" ;;
    *) continue ;;
  esac
  [ "$(lower "$other")" != "$(lower "$RELAYER")" ] || die "the relayer matches $name in .env (C65)"
  wallets_checked=$((wallets_checked + 1))
done < <(grep -E '^[A-Z0-9_]+=' .env)
[ "$(lower "$RELAYER")" != "$(lower "$(read_now "$FAUCET" "owner()(address)")")" ] || die "the relayer is the owner (C65)"
[ "$wallets_checked" -gt 0 ] || die "found no other wallet in .env to check the relayer against"
echo "   relayer $RELAYER differs from the owner and from all $wallets_checked other wallet entries in .env"

mkdir -p "$SCRATCH_DIR"
touch "$PROGRESS" "$TX_LOG"
done_value() { grep -E "^$1=" "$PROGRESS" | tail -1 | cut -d= -f2- || true; }
mark() { echo "$1=$2" >> "$PROGRESS"; }
if [ -n "$(done_value FAUCET)" ]; then
  [ "$(lower "$(done_value FAUCET)")" = "$(lower "$FAUCET")" ] \
    || die "$PROGRESS belongs to Faucet $(done_value FAUCET), not $FAUCET; move it aside first"
else
  mark FAUCET "$FAUCET"
fi

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
RELAYER_NONCE="$(fresh_nonce "$RELAYER")"

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

# expect_refusal <label> <from> <expected revert data> <cast call arguments...>: the call must revert with exactly
# this data. A success or another error may come from a node that has not seen the last receipt yet, so it is asked
# again, and only a run of 120 s without the expected refusal fails.
expect_refusal() {
  local label="$1" from="$2" want="$3" out=""
  shift 3
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast call --from "$from" "$@" --rpc-url "$RPC" 2>&1)"; then
      out="the call succeeded"
    elif lower "$out" | grep -q "data: \"$(lower "$want")\""; then
      echo "   refused as it must be: $label"
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "$label: expected revert data $want, last answer: $(printf '%s' "$out" | tr '\r\n' '  ')"
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
# DEPLOYER or RELAYER.
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

# event_value <hash> <emitter> <event signature> <field>: prints one field of the first matching log in the receipt
# as a decimal number. A field is a topic index, a data word written d0, d1 and so on, or "count" for how many logs
# match.
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
found = [l for l in logs if l["address"].lower() == emitter and l["topics"][0].lower() == topic]
if not found:
    sys.exit(1)
if field == "count":
    print(len(found))
elif field.startswith("d"):
    word = int(field[1:])
    print(int(found[0]["data"][2:][64 * word:64 * (word + 1)], 16))
else:
    print(int(found[0]["topics"][int(field)], 16))
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

# remember <key> <command...>: records the command's answer under <key> once. A die inside $(...) only ends the
# subshell, so the failure is caught here and stops the run instead of recording an empty value.
remember() {
  local key="$1" value
  shift
  [ -n "$(done_value "$key")" ] && return 0
  value="$("$@")" || die "could not work out $key"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$key came back as '$value', not a number"
  mark "$key" "$value"
}

# A fresh address from random bytes: no key for it ever exists, so there is nothing to keep or leak.
random_address() {
  cast to-check-sum-address "$("$PY" -I -c 'import secrets; print("0x" + secrets.token_hex(20))' | tr -d '\r')" | tr -d '\r'
}

as_number() { "$PY" -I -c 'import sys; print(int(sys.argv[1], 16))' "$1" | tr -d '\r'; }

echo "== Step 2: the deployer funds the faucet and the relayer"
NEED_BTC=0
NEED_MUSD=0
[ -n "$(done_value FUND_FAUCET_BTC_HASH)" ] || NEED_BTC=$((NEED_BTC + FAUCET_BTC_WEI))
[ -n "$(done_value FUND_RELAYER_HASH)" ] || NEED_BTC=$((NEED_BTC + RELAYER_BTC_WEI))
[ -n "$(done_value FUND_FAUCET_MUSD_HASH)" ] || NEED_MUSD="$FAUCET_MUSD_WEI"
DEPLOYER_BTC="$(cast balance "$DEPLOYER" --rpc-url "$RPC" | tr -d '\r')"
DEPLOYER_MUSD="$(read_now "$MUSD" "balanceOf(address)(uint256)" "$DEPLOYER")"
echo "   deployer holds $(shown "$DEPLOYER_BTC") test BTC and $(shown "$DEPLOYER_MUSD") test MUSD"
if [ "$NEED_BTC" -gt 0 ] && [ "$DEPLOYER_BTC" -lt $((NEED_BTC + DEPLOYER_RESERVE_WEI)) ]; then
  die "the deployer holds $(shown "$DEPLOYER_BTC") test BTC, and this run needs $(shown "$NEED_BTC") plus $(shown "$DEPLOYER_RESERVE_WEI") kept for gas"
fi
[ "$("$PY" -I -c 'import sys; print(int(int(sys.argv[1]) >= int(sys.argv[2])))' "$DEPLOYER_MUSD" "$NEED_MUSD" | tr -d '\r')" = "1" ] \
  || die "the deployer holds $(shown "$DEPLOYER_MUSD") test MUSD, and this run needs $(shown "$NEED_MUSD")"

step FUND_FAUCET_BTC "send 0.0011 BTC to the faucet" DEPLOYER "$GAS_VALUE" "$FAUCET" --value "$FAUCET_BTC_WEI"
step FUND_FAUCET_MUSD "MUSD.transfer(faucet, 30 MUSD)" DEPLOYER "$GAS_TRANSFER" \
  "$MUSD" "transfer(address,uint256)" "$FAUCET" "$FAUCET_MUSD_WEI"
step FUND_RELAYER "send 0.0002 BTC to the relayer" DEPLOYER "$GAS_VALUE" "$RELAYER" --value "$RELAYER_BTC_WEI"
FUNDED_BLOCK="$SENT_BLOCK"

echo "== Step 3: the relayer claims one kit for a fresh random address"
if [ -z "$(done_value FRESH)" ]; then mark FRESH "$(random_address)"; fi
if [ -z "$(done_value PROBE)" ]; then mark PROBE "$(random_address)"; fi
if [ -z "$(done_value STRANGER)" ]; then mark STRANGER "$(random_address)"; fi
FRESH="$(done_value FRESH)"
PROBE="$(done_value PROBE)"
STRANGER="$(done_value STRANGER)"
if [ -z "$(done_value CLAIM_HASH)" ]; then
  remember BEFORE_OPEN read_at "$FUNDED_BLOCK" "$FAUCET" "claimsOpen()(uint256)"
  remember BEFORE_NEXT read_at "$FUNDED_BLOCK" "$FAUCET" "nextOpenAt()(uint256)"
  remember BEFORE_BTC balance_at "$FRESH" "$FUNDED_BLOCK"
  remember BEFORE_MUSD read_at "$FUNDED_BLOCK" "$MUSD" "balanceOf(address)(uint256)" "$FRESH"
  remember BEFORE_CODE cast codesize "$FRESH" --rpc-url "$RPC"
fi
FUNDED_TIME="$(cast block "$FUNDED_BLOCK" --field timestamp --rpc-url "$RPC" | awk '{print $1}')"
echo "   before the claim: claimsOpen $(done_value BEFORE_OPEN) (expected 1), nextOpenAt $(done_value BEFORE_NEXT) (the funding block's time, $FUNDED_TIME)"
[ "$(done_value BEFORE_OPEN)" = "1" ] || die "claimsOpen should read 1 with one kit funded, read $(done_value BEFORE_OPEN)"
[ "$(done_value BEFORE_NEXT)" = "$FUNDED_TIME" ] || die "nextOpenAt should read the block's time while a claim is open"
echo "   fresh address $FRESH holds $(shown "$(done_value BEFORE_BTC)") BTC and $(shown "$(done_value BEFORE_MUSD)") MUSD, code size $(done_value BEFORE_CODE)"
[ "$(done_value BEFORE_BTC)" = "0" ] && [ "$(done_value BEFORE_MUSD)" = "0" ] && [ "$(done_value BEFORE_CODE)" = "0" ] \
  || die "the random address is not fresh"

step CLAIM "Faucet.claim(fresh address) by the relayer" RELAYER "$GAS_CLAIM" "$FAUCET" "claim(address)" "$FRESH"
CLAIM_HASH="$SENT_HASH"
CLAIM_BLOCK="$SENT_BLOCK"
CLAIMED_EVENT="Claimed(address,uint256,uint256,uint256)"
[ "$(event_value "$CLAIM_HASH" "$FAUCET" "$CLAIMED_EVENT" count)" = "1" ] || die "the claim must emit exactly one Claimed event"
[ "$(event_value "$CLAIM_HASH" "$FAUCET" "$CLAIMED_EVENT" 1)" = "$(as_number "$FRESH")" ] || die "Claimed names another address"
EVENT_BTC="$(event_value "$CLAIM_HASH" "$FAUCET" "$CLAIMED_EVENT" d0)"
EVENT_MUSD="$(event_value "$CLAIM_HASH" "$FAUCET" "$CLAIMED_EVENT" d1)"
EVENT_DAY="$(event_value "$CLAIM_HASH" "$FAUCET" "$CLAIMED_EVENT" 2)"
[ "$EVENT_BTC" = "$BTC_KIT_WEI" ] && [ "$EVENT_MUSD" = "$MUSD_KIT_WEI" ] || die "Claimed reports another kit"
echo "   Claimed event: one, naming $FRESH, $(shown "$EVENT_BTC") BTC, $(shown "$EVENT_MUSD") MUSD, UTC day $EVENT_DAY"
remember AFTER_BTC balance_at "$FRESH" "$CLAIM_BLOCK"
remember AFTER_MUSD read_at "$CLAIM_BLOCK" "$MUSD" "balanceOf(address)(uint256)" "$FRESH"
remember AFTER_FAUCET_BTC balance_at "$FAUCET" "$CLAIM_BLOCK"
remember AFTER_FAUCET_MUSD read_at "$CLAIM_BLOCK" "$MUSD" "balanceOf(address)(uint256)" "$FAUCET"
remember AFTER_OPEN read_at "$CLAIM_BLOCK" "$FAUCET" "claimsOpen()(uint256)"
remember AFTER_NEXT read_at "$CLAIM_BLOCK" "$FAUCET" "nextOpenAt()(uint256)"
remember AFTER_TODAY read_at "$CLAIM_BLOCK" "$FAUCET" "claimsToday()(uint256)"
[ "$(done_value AFTER_BTC)" = "$BTC_KIT_WEI" ] || die "the fresh address holds $(done_value AFTER_BTC) wei BTC, not one kit"
[ "$(done_value AFTER_MUSD)" = "$MUSD_KIT_WEI" ] || die "the fresh address holds $(done_value AFTER_MUSD) wei MUSD, not one kit"
[ "$(read_at "$CLAIM_BLOCK" "$FAUCET" "claimed(address)(bool)" "$FRESH")" = "true" ] || die "claimed(fresh) is not true"
echo "   the kit arrived, block $CLAIM_BLOCK: $FRESH holds $(shown "$(done_value AFTER_BTC)") BTC and $(shown "$(done_value AFTER_MUSD)") MUSD, claimed true"
echo "   the faucet keeps $(shown "$(done_value AFTER_FAUCET_BTC)") BTC and $(shown "$(done_value AFTER_FAUCET_MUSD)") MUSD, claimsToday $(done_value AFTER_TODAY)"

echo "== Step 4: the faucet is now short of a kit, so both views must read 0"
[ "$(done_value AFTER_FAUCET_BTC)" -lt "$BTC_KIT_WEI" ] || die "the faucet still holds a full BTC kit"
[ "$(done_value AFTER_OPEN)" = "0" ] || die "claimsOpen should read 0 short of a kit, read $(done_value AFTER_OPEN)"
[ "$(done_value AFTER_NEXT)" = "0" ] || die "nextOpenAt should read 0 short of a kit, read $(done_value AFTER_NEXT)"
echo "   check passed: claimsOpen $(done_value AFTER_OPEN), nextOpenAt $(done_value AFTER_NEXT), at the claim's block, with $(shown "$(done_value AFTER_FAUCET_BTC)") BTC left against a 0.001 BTC kit"

echo "== Step 5: refusals, simulated from each caller"
CLAIM_CALL=("$FAUCET" "claim(address)")
expect_refusal "a second claim for the same address: AlreadyClaimed($FRESH)" "$RELAYER" \
  "$(cast calldata "AlreadyClaimed(address)" "$FRESH")" "${CLAIM_CALL[@]}" "$FRESH"
expect_refusal "a stranger $STRANGER: NotRelayer" "$STRANGER" \
  "$(cast calldata "NotRelayer()")" "${CLAIM_CALL[@]}" "$PROBE"

echo "== Step 6: a paused faucet refuses, then resumes"
ENFORCED_PAUSE="$(cast calldata "EnforcedPause()")"
NO_CLAIM_OPEN="$(cast calldata "NoClaimOpen(uint256)" 0)"
if [ -n "$(done_value UNPAUSE_HASH)" ]; then
  echo "   paused and resumed in an earlier run; the paused refusal was shown then and was recorded: $(done_value PAUSED_REFUSAL)"
else
  step PAUSE "Faucet.pause() by the owner" DEPLOYER "$GAS_PAUSE" "$FAUCET" "pause()"
  PAUSE_BLOCK="$SENT_BLOCK"
  [ "$(read_at "$PAUSE_BLOCK" "$FAUCET" "paused()(bool)")" = "true" ] || die "paused() is not true after pause"
  expect_refusal "a claim while paused: EnforcedPause" "$RELAYER" "$ENFORCED_PAUSE" "${CLAIM_CALL[@]}" "$PROBE"
  mark PAUSED_REFUSAL EnforcedPause
  echo "   while paused: claimsOpen $(read_at "$PAUSE_BLOCK" "$FAUCET" "claimsOpen()(uint256)"), nextOpenAt $(read_at "$PAUSE_BLOCK" "$FAUCET" "nextOpenAt()(uint256)")"
  step UNPAUSE "Faucet.unpause() by the owner" DEPLOYER "$GAS_PAUSE" "$FAUCET" "unpause()"
  UNPAUSE_BLOCK="$SENT_BLOCK"
  [ "$(read_at "$UNPAUSE_BLOCK" "$FAUCET" "paused()(bool)")" = "false" ] || die "paused() is not false after unpause"
fi
echo "   resumed: paused() reads $(read_now "$FAUCET" "paused()(bool)")"

echo "== Step 7: where the faucet stands now"
FAUCET_BTC="$(cast balance "$FAUCET" --rpc-url "$RPC" | tr -d '\r')"
FAUCET_MUSD="$(read_now "$MUSD" "balanceOf(address)(uint256)" "$FAUCET")"
OPEN_NOW="$(read_now "$FAUCET" "claimsOpen()(uint256)")"
NEXT_NOW="$(read_now "$FAUCET" "nextOpenAt()(uint256)")"
echo "   Faucet $FAUCET holds $(shown "$FAUCET_BTC") BTC and $(shown "$FAUCET_MUSD") MUSD"
echo "   claimsOpen $OPEN_NOW, nextOpenAt $NEXT_NOW, claimsToday $(read_now "$FAUCET" "claimsToday()(uint256)")"
if [ "$FAUCET_BTC" -lt "$BTC_KIT_WEI" ]; then
  expect_refusal "a claim on the resumed faucet, short of a kit, not paused: NoClaimOpen(0)" "$RELAYER" \
    "$NO_CLAIM_OPEN" "${CLAIM_CALL[@]}" "$PROBE"
else
  echo "   the faucet has been refilled since the proof, so the short-of-a-kit refusal is not repeated"
fi
echo "   relayer holds $(shown "$(cast balance "$RELAYER" --rpc-url "$RPC" | tr -d '\r')") BTC"
DEPLOYER_LEFT="$(cast balance "$DEPLOYER" --rpc-url "$RPC" | tr -d '\r')"
echo "   deployer keeps $(shown "$DEPLOYER_LEFT") BTC for gas"
echo "   transactions:"
while IFS='|' read -r label hash block gas_used; do
  echo "     $label: $hash (block $block, gas $gas_used)"
done < "$TX_LOG"
echo "Faucet proven live on Mezo testnet"
