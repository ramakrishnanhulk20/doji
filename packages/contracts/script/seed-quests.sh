#!/usr/bin/env bash
# Gets Mezo testnet ready for quest testers, with cast, against deployments/31611-wave2.json and
# deployments/31611-faucet.json. The DEPLOYER swaps 0.0105 test BTC for MUSD, fills the Faucet with 750 MUSD and 0.03
# BTC, posts a parked 40 MUSD offer on each Thursday from 12 Nov to 3 Dec, and funds BORROWER_2. BORROWER_2 opens three
# 10 MUSD loans due 12 Nov on 0.0004 BTC each and leaves them unpaid on purpose, so small positions reach auction after
# that date at prices a tester can afford. BORROWER repays loan #412 in full, so its large position does not reach
# auction then. Every call is simulated from its sender before it is sent. Prints every transaction's label and hash,
# then writes deployments/31611-seed.json.
#
# What it does NOT prove: the auctions. None can start before 12 Nov 00:00 UTC, someone still has to call startAuction
# then, and their prices follow the BTC price on the day. It also does not show the warning a tester sees before
# lending at a date holding a seed loan (F44, C80), which is the site's job.
#
# Doji's own wallets only (C75): this script holds the list it may sign with, and refuses to run if one of them is
# missing from packages/web/src/lib/doji-wallets.ts or if a key in .env signs as any other wallet. It covers these three
# wallets and does not cover what a wallet does outside this script. Seed wallets hold no role and use no private path
# (C80), and each seed loan is checked to carry collateral above its debt.
#
# Safe to run again after a failure: every transaction is recorded in scratchpad/seed-quests/progress.env the moment it
# is sent, so nothing is sent twice. One sent without a receipt is looked up on the next run, never resent. That file is
# tied to this deployment and refused for any other. A finished run sends nothing, repeats the reads and writes the same
# record.
#
# Cost per run: 0.0421 test BTC from DEPLOYER (0.0105 swapped, 0.03 to the Faucet, 0.0016 to BORROWER_2), 910 test MUSD
# from DEPLOYER (750 to the Faucet, 160 in offers), 0.0012 test BTC locked by BORROWER_2, what #412 still owes from
# BORROWER, and testnet gas. It refuses to start if any step left could not be paid for.
#
# Usage, from anywhere: bash packages/contracts/script/seed-quests.sh
# Reads the three wallets' keys and MEZO_TESTNET_RPC from packages/contracts/.env. Keys go to cast only and are never
# printed.
set -euo pipefail
# Bash drops -e inside $(...) unless told otherwise, and a failed read there must stop the run.
shopt -s inherit_errexit

export PATH="$HOME/.foundry/bin:$PATH"

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CONTRACTS_DIR/../.." && pwd)"
SCRATCH_DIR="$REPO_DIR/scratchpad/seed-quests"
PROGRESS="$SCRATCH_DIR/progress.env"
TX_LOG="$SCRATCH_DIR/transactions.txt"
WALLET_LIST="$REPO_DIR/packages/web/src/lib/doji-wallets.ts"
CHAIN_ID=31611
EXPLORER="https://explorer.test.mezo.org"
WAVE2_RECORD="deployments/$CHAIN_ID-wave2.json"
FAUCET_RECORD="deployments/$CHAIN_ID-faucet.json"
SEED_RECORD="deployments/$CHAIN_ID-seed.json"

# The only wallets this script may sign with (C75). Public addresses, so they are held here rather than read from .env,
# which is where a wrong key would come from.
DEPLOYER=0xd338Ad588D6c3aE127FD5eEC6843A468d3a7aa6e
BORROWER=0x92DcCb70C33300848Da555eDe8597d3F7037AE2b
BORROWER_2=0xb164F15b59DFd9eb7eac60A364ce3F0f6721A5Ef
SIGNERS=(DEPLOYER BORROWER BORROWER_2)

MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
BTC=0x7b7C000000000000000000000000000000000000
FACTORY=0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A
FAUCET=0xCd80D2ef1D47db5c5bc784DE5Ac7a980F8E97BAa
LARGE_LOAN=412

NOV12=1794441600
NOV19=1795046400
NOV26=1795651200
DEC3=1796256000
OFFER_DATES=("$NOV12" "$NOV19" "$NOV26" "$DEC3")
OFFER_APRS=(550 600 650 700)

SWAP_BTC_WEI=10500000000000000
SWAP_MIN_WEI=800000000000000000000
SWAP_DEADLINE_SECONDS=1200
FAUCET_MUSD_WEI=750000000000000000000
FAUCET_BTC_WEI=30000000000000000
OFFER_WEI=40000000000000000000
BORROWER_2_BTC_WEI=1600000000000000
LOCK_BTC_WEI=400000000000000
LOCK_SECONDS=2419200
LOAN_WEI=10000000000000000000
LOAN_COUNT=3
# nextOfferId is below 10 today. A list far past that means something other than seeding is happening, so stop.
MAX_OFFER_SCAN=200
DEPLOYER_RESERVE_WEI=900000000000000
BORROWER_RESERVE_WEI=100000000000000

# wave2-live.sh's limits for the calls it shares with this script. faucet-live.sh's for the MUSD transfer. The swap's is
# the limit its live run used on 2026-11-05 and the repay's is savings-slice.sh's. Mezo charges at least half of the
# limit, and gas is priced at a few hundred wei, so the headroom costs almost nothing.
GAS_APPROVE=150000
GAS_TRANSFER=150000
GAS_VALUE=100000
GAS_SWAP=500000
GAS_POST=1000000
GAS_LOCK_BORROW=2500000
GAS_REPAY=1000000

# Some nodes behind the public RPC lag the others, so a read, a receipt or a simulation right after a receipt is
# asked again for up to 120 s before it counts as failed.
WAIT_TRIES=40
WAIT_SECONDS=3

die() { echo "SEED QUESTS STOPPED: $*" >&2; exit 1; }

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
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r' || true; }
RPC="${MEZO_TESTNET_RPC:-$(env_value MEZO_TESTNET_RPC)}"
[ -n "$RPC" ] || die "MEZO_TESTNET_RPC is not set"
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || die "MEZO_TESTNET_RPC is not Mezo testnet (chain $CHAIN_ID)"
PY="$(pick_python)"

# MUSD amounts in wei are past what bash arithmetic can hold, so every sum and comparison of them goes through python.
at_least() { "$PY" -I -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$1" "$2"; }
sum_of() { "$PY" -I -c 'import sys; print(sum(int(x) for x in sys.argv[1:]))' "$@" | tr -d '\r'; }
# words <raw return value> <count>: prints that many 32-byte words as decimal numbers.
words() {
  "$PY" -I -c '
import sys
raw = sys.argv[1][2:]
print(*(int(raw[64 * i:64 * (i + 1)], 16) for i in range(int(sys.argv[2]))))' "$1" "$2" | tr -d '\r'
}

record() {
  "$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(native_path "$CONTRACTS_DIR/$1")" "$2" \
    | tr -d '\r'
}
for file in "$WAVE2_RECORD" "$FAUCET_RECORD"; do
  [ -f "$file" ] || die "$file is missing"
  [ "$(record "$file" broadcast)" = "True" ] || die "$file is not a broadcast record"
  [ "$(record "$file" chainId)" = "$CHAIN_ID" ] || die "$file is not for chain $CHAIN_ID"
done
CM="$(record "$WAVE2_RECORD" creditMarkets)"
LM="$(record "$WAVE2_RECORD" loanManager)"
PD="$(record "$WAVE2_RECORD" payDown)"
ROUTER="$(record "$WAVE2_RECORD" router)"
VEBTC="$(record "$WAVE2_RECORD" veBTC)"
[ "$(lower "$(record "$WAVE2_RECORD" factory)")" = "$(lower "$FACTORY")" ] || die "$WAVE2_RECORD names another factory"
[ "$(lower "$(record "$WAVE2_RECORD" musd)")" = "$(lower "$MUSD")" ] || die "$WAVE2_RECORD names another MUSD"
[ "$(lower "$(record "$WAVE2_RECORD" btc)")" = "$(lower "$BTC")" ] || die "$WAVE2_RECORD names another BTC"
[ "$(lower "$(record "$FAUCET_RECORD" faucet)")" = "$(lower "$FAUCET")" ] || die "$FAUCET_RECORD names another Faucet"
for target in "$CM" "$LM" "$PD" "$ROUTER" "$VEBTC" "$FAUCET"; do
  [[ "$target" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "a record names a bad address: $target"
  [ "$(cast codesize "$target" --rpc-url "$RPC")" != "0" ] || die "no code at $target"
done
[ "$(lower "$(cast call "$PD" "loanManager()(address)" --rpc-url "$RPC")")" = "$(lower "$LM")" ] \
  || die "PayDown does not point at this LoanManager"
[ "$(lower "$(cast call "$FAUCET" "musd()(address)" --rpc-url "$RPC")")" = "$(lower "$MUSD")" ] \
  || die "the Faucet does not pay this MUSD"

mkdir -p "$SCRATCH_DIR"
touch "$PROGRESS" "$TX_LOG"
done_value() { grep -E "^$1=" "$PROGRESS" | tail -1 | cut -d= -f2- || true; }
mark() { echo "$1=$2" >> "$PROGRESS"; }
for tie in CREDIT_MARKETS:"$CM" LOAN_MANAGER:"$LM" FAUCET:"$FAUCET"; do
  tie_key="${tie%%:*}"
  tie_address="${tie#*:}"
  if [ -n "$(done_value "$tie_key")" ]; then
    [ "$(lower "$(done_value "$tie_key")")" = "$(lower "$tie_address")" ] \
      || die "$PROGRESS belongs to $tie_key $(done_value "$tie_key"), not $tie_address; move it aside first"
  else
    mark "$tie_key" "$tie_address"
  fi
done

link() { echo "$EXPLORER/tx/$1"; }

# True once a step has left this machine, whether or not its receipt has been seen.
handled() { [ -n "$(done_value "${1}_HASH")" ] || [ -n "$(done_value "${1}_SENT")" ]; }

latest_block() {
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast block-number --rpc-url "$RPC" 2>/dev/null)" && [ -n "$out" ]; then
      printf '%s' "$out" | tr -d '\r'
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  die "could not read the latest block"
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

# Reads a value at a pinned block, asking again while a lagging node has not reached that block yet. Prints the
# first word of the first line, which is the decoded value without cast's scientific-notation hint.
read_at() {
  local block="$1"
  shift
  local out
  for _ in $(seq 1 "$WAIT_TRIES"); do
    if out="$(cast call "$@" --block "$block" --rpc-url "$RPC" 2>/dev/null)"; then
      printf '%s' "$out" | head -1 | awk '{print $1}' | tr -d '\r'
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

# A block no node should answer for from before the last receipt: the latest one, or the last send's if the node asked
# is behind it.
SENT_HASH=""
SENT_BLOCK=""
pin_block() {
  local latest
  latest="$(latest_block)"
  if [ -n "$SENT_BLOCK" ] && [ "$latest" -lt "$SENT_BLOCK" ]; then echo "$SENT_BLOCK"; else echo "$latest"; fi
}

swap_quote() {
  local raw
  raw="$(read_raw_at "$1" "$ROUTER" "getAmountsOut(uint256,(address,address,bool,address)[])" "$SWAP_BTC_WEI" \
    "[($BTC,$MUSD,false,$FACTORY)]")"
  words "$raw" 4 | awk '{print $4}'
}

faucet_report() {
  local block="$1" open held_btc held_musd per_btc per_musd kits
  open="$(read_at "$block" "$FAUCET" "claimsOpen()(uint256)")"
  held_btc="$(balance_at "$FAUCET" "$block")"
  held_musd="$(read_at "$block" "$MUSD" "balanceOf(address)(uint256)" "$FAUCET")"
  per_btc="$(read_at "$block" "$FAUCET" "btcPerClaim()(uint128)")"
  per_musd="$(read_at "$block" "$FAUCET" "musdPerClaim()(uint128)")"
  kits="$("$PY" -I -c 'import sys; a = [int(x) for x in sys.argv[1:]]; print(min(a[0] // a[1], a[2] // a[3]))' \
    "$held_btc" "$per_btc" "$held_musd" "$per_musd" | tr -d '\r')"
  echo "   Faucet holds $(shown "$held_btc") BTC and $(shown "$held_musd") MUSD: kits held $kits, claimsOpen $open"
}

echo "== Wave 2 contracts"
echo "   CreditMarkets $CM"
echo "   LoanManager   $LM"
echo "   PayDown       $PD"
echo "   Router        $ROUTER"
echo "   Faucet        $FAUCET"

echo "== Balances before anything"
LATEST="$(latest_block)"
DEPLOYER_BTC="$(balance_at "$DEPLOYER" "$LATEST")"
DEPLOYER_MUSD="$(read_at "$LATEST" "$MUSD" "balanceOf(address)(uint256)" "$DEPLOYER")"
BORROWER_BTC="$(balance_at "$BORROWER" "$LATEST")"
BORROWER_MUSD="$(read_at "$LATEST" "$MUSD" "balanceOf(address)(uint256)" "$BORROWER")"
BORROWER_2_BTC="$(balance_at "$BORROWER_2" "$LATEST")"
BORROWER_2_MUSD="$(read_at "$LATEST" "$MUSD" "balanceOf(address)(uint256)" "$BORROWER_2")"
echo "   read at block $LATEST"
echo "   DEPLOYER   $DEPLOYER holds $(shown "$DEPLOYER_BTC") BTC and $(shown "$DEPLOYER_MUSD") MUSD"
echo "   BORROWER   $BORROWER holds $(shown "$BORROWER_BTC") BTC and $(shown "$BORROWER_MUSD") MUSD"
echo "   BORROWER_2 $BORROWER_2 holds $(shown "$BORROWER_2_BTC") BTC and $(shown "$BORROWER_2_MUSD") MUSD"
faucet_report "$LATEST"

echo "== Can every step left be paid for?"
NOW="$(block_time "$LATEST")"
MAX_TERM="$(read_at "$LATEST" "$CM" "maxTermSeconds()(uint32)")"
OFFERS_WEI=0
for date in "${OFFER_DATES[@]}"; do
  key="OFFER_$date"
  if handled "$key" || [ -n "$(done_value "${key}_SKIPPED")" ]; then continue; fi
  if [ "$(read_at "$LATEST" "$CM" "isValidMaturity(uint64)(bool)" "$date")" = "true" ]; then
    OFFERS_WEI="$(sum_of "$OFFERS_WEI" "$OFFER_WEI")"
  elif [ "$date" -gt $((NOW + MAX_TERM)) ]; then
    mark "${key}_SKIPPED" "past the maximum term of $MAX_TERM s at chain time $NOW"
  else
    die "maturity $date is not open on CreditMarkets"
  fi
done

NEED_BTC=0
handled SWAP || NEED_BTC=$((NEED_BTC + SWAP_BTC_WEI))
handled FAUCET_BTC || NEED_BTC=$((NEED_BTC + FAUCET_BTC_WEI))
handled FUND_BORROWER_2 || NEED_BTC=$((NEED_BTC + BORROWER_2_BTC_WEI))
if [ "$NEED_BTC" -gt 0 ] && [ "$DEPLOYER_BTC" -lt $((NEED_BTC + DEPLOYER_RESERVE_WEI)) ]; then
  die "DEPLOYER holds $(shown "$DEPLOYER_BTC") BTC, and the steps left need $(shown "$NEED_BTC") plus $(shown "$DEPLOYER_RESERVE_WEI") kept for gas"
fi

NEED_MUSD="$OFFERS_WEI"
handled FAUCET_MUSD || NEED_MUSD="$(sum_of "$NEED_MUSD" "$FAUCET_MUSD_WEI")"
EXPECTED_MUSD="$DEPLOYER_MUSD"
if ! handled SWAP; then
  QUOTE="$(swap_quote "$LATEST")"
  echo "   Router quotes $(shown "$QUOTE") MUSD for 0.0105 BTC"
  at_least "$QUOTE" "$SWAP_MIN_WEI" || die "the Router quotes $(shown "$QUOTE") MUSD, under the 800 MUSD minimum; not swapping"
  EXPECTED_MUSD="$(sum_of "$EXPECTED_MUSD" "$SWAP_MIN_WEI")"
fi
at_least "$EXPECTED_MUSD" "$NEED_MUSD" \
  || die "DEPLOYER would hold $(shown "$EXPECTED_MUSD") MUSD, and the steps left need $(shown "$NEED_MUSD")"

LOANS_LEFT=0
for n in $(seq 1 "$LOAN_COUNT"); do
  handled "LOAN_$n" || LOANS_LEFT=$((LOANS_LEFT + 1))
done
EXPECTED_BTC="$BORROWER_2_BTC"
handled FUND_BORROWER_2 || EXPECTED_BTC=$((EXPECTED_BTC + BORROWER_2_BTC_WEI))
if [ "$LOANS_LEFT" -gt 0 ] && [ "$EXPECTED_BTC" -lt $((LOANS_LEFT * LOCK_BTC_WEI + BORROWER_RESERVE_WEI)) ]; then
  die "BORROWER_2 would hold $(shown "$EXPECTED_BTC") BTC, and $LOANS_LEFT loans need 0.0004 each plus $(shown "$BORROWER_RESERVE_WEI") kept for gas"
fi

if ! handled REPAY; then
  LARGE_OWED="$(read_at "$LATEST" "$LM" "owedOf(uint256)(uint256)" "$LARGE_LOAN")"
  at_least "$BORROWER_MUSD" "$LARGE_OWED" \
    || die "BORROWER holds $(shown "$BORROWER_MUSD") MUSD, and #$LARGE_LOAN owes $(shown "$LARGE_OWED")"
  [ "$BORROWER_BTC" -ge "$BORROWER_RESERVE_WEI" ] \
    || die "BORROWER holds $(shown "$BORROWER_BTC") BTC, under the $(shown "$BORROWER_RESERVE_WEI") kept for gas"
fi
echo "   yes: every step left can be paid for"

echo "== Step 1: only wallets on Doji's list may sign (C75)"
[ -f "$WALLET_LIST" ] || die "C75: $WALLET_LIST is missing, so no wallet can be checked; refusing to sign"
# Entries only, so an address in a comment does not count as listed. Both sides are lowered by the same tool.
LISTED="$(grep -oE '^[[:space:]]*"0x[0-9a-fA-F]{40}"' "$WALLET_LIST" | grep -oE '0x[0-9a-fA-F]{40}' | tr '[:upper:]' '[:lower:]' || true)"
for who in "${SIGNERS[@]}"; do
  grep -qxF "$(lower "${!who}")" <<<"$LISTED" \
    || die "C75: $who ${!who} is not in packages/web/src/lib/doji-wallets.ts; refusing to sign"
  echo "   $who ${!who} is on the list"
done
DEPLOYER_KEY="$(env_value DEPLOYER_PRIVATE_KEY)"
BORROWER_KEY="$(env_value BORROWER_PRIVATE_KEY)"
BORROWER_2_KEY="$(env_value BORROWER2_PRIVATE_KEY)"
for who in "${SIGNERS[@]}"; do
  key_var="${who}_KEY"
  [ -n "${!key_var}" ] || die "no key for $who in .env"
  # Errors stay hidden because cast repeats a malformed key in them.
  signs_as="$(cast wallet address --private-key "${!key_var}" 2>/dev/null)" || die "the key for $who in .env is not a valid key"
  [ "$(lower "$signs_as")" = "$(lower "${!who}")" ] \
    || die "C75: the key for $who in .env signs as $signs_as, not ${!who}; refusing to sign"
done
echo "   each key signs as its listed wallet"

# A lagging node can report an old pending nonce, so each wallet's nonce is read a few times, the highest kept, and
# tracked here from then on.
fresh_nonce() {
  local best=0 n
  for _ in 1 2 3; do
    n="$(cast nonce "$1" --block pending --rpc-url "$RPC" | tr -d '\r')"
    [ "$n" -gt "$best" ] && best="$n"
  done
  echo "$best"
}
for who in "${SIGNERS[@]}"; do
  start_nonce="$(fresh_nonce "${!who}")"
  printf -v "${who}_NONCE" '%d' "$start_nonce"
  printf -v "${who}_START_NONCE" '%d' "$start_nonce"
done

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
    [ -n "$out" ] && { printf '%s' "$out" | awk '{print $1}' | tr -d '\r'; return 0; }
    sleep "$WAIT_SECONDS"
  done
  die "could not read $2 of receipt $1"
}

# confirm <label> <hash>: waits for the receipt, logs the transaction and sets SENT_HASH and SENT_BLOCK. The stop for a
# missing receipt names the way out, because the step's _SENT line then keeps every later run from sending it again.
confirm() {
  local label="$1" hash="$2" status gas_used
  status="$(receipt_status "$hash")" \
    || die "$label: no receipt after $((WAIT_TRIES * WAIT_SECONDS)) s for $hash; run again later, it will not be resent. If the explorer never shows it, remove its _SENT line from $PROGRESS first"
  case "$(lower "$(printf '%s' "$status" | awk '{print $1}')")" in
    true | 1 | 0x1 | success) ;;
    *) die "$label failed: status $status, $(link "$hash")" ;;
  esac
  SENT_HASH="$hash"
  SENT_BLOCK="$(receipt_field "$hash" blockNumber)"
  gas_used="$(receipt_field "$hash" gasUsed)"
  echo "$label|$hash|$SENT_BLOCK|$gas_used" >> "$TX_LOG"
  echo "   tx $label: ok $hash block $SENT_BLOCK gas $gas_used $(link "$hash")"
}

# send <key> <label> <wallet> <gas> <cast send arguments...>: refuses a wallet off the list, simulates from the wallet,
# sends with the tracked nonce and an explicit gas limit, and records the hash before waiting for its receipt.
SENT_THIS_RUN=0
send() {
  local key="$1" label="$2" who="$3" gas="$4"
  shift 4
  case " ${SIGNERS[*]} " in
    *" $who "*) ;;
    *) die "C75: $who is not a wallet this script may sign with" ;;
  esac
  local from="${!who}" key_var="${who}_KEY" nonce_var="${who}_NONCE" hash
  try_simulate "$from" "$@" || die "$label: simulation from $from still fails after $((WAIT_TRIES * WAIT_SECONDS)) s: $SIM_ERR"
  hash="$(cast send --async --private-key "${!key_var}" --nonce "${!nonce_var}" --gas-limit "$gas" "$@" --rpc-url "$RPC")"
  [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "$label: cast send returned no transaction hash"
  mark "${key}_SENT" "$hash"
  printf -v "$nonce_var" '%d' $((${!nonce_var} + 1))
  SENT_THIS_RUN=$((SENT_THIS_RUN + 1))
  confirm "$label" "$hash"
}

# step <key> <label> <wallet> <gas> <cast send arguments...>: sends once. A key already in the progress file means an
# earlier run sent it, so its hash and block are read back from there, or its receipt is looked up if that run never
# saw one.
step() {
  local key="$1" label="$2"
  shift 2
  if [ -n "$(done_value "${key}_HASH")" ]; then
    SENT_HASH="$(done_value "${key}_HASH")"
    SENT_BLOCK="$(done_value "${key}_BLOCK")"
    echo "   tx $label: sent in an earlier run, $SENT_HASH block $SENT_BLOCK"
    return 0
  fi
  if [ -n "$(done_value "${key}_SENT")" ]; then
    echo "   tx $label: sent in an earlier run with no receipt seen, looking it up"
    confirm "$label" "$(done_value "${key}_SENT")"
  else
    send "$key" "$label" "$@"
  fi
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
    if log["address"].lower() == emitter and log["topics"] and log["topics"][0].lower() == topic:
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

# Sets PICK_ID and PICK_APR to the cheapest offer at 12 Nov that can lend a whole seed loan. On a tie the older offer.
pick_offer() {
  local block="$1" next id row maturity apr remaining
  PICK_ID=""
  PICK_APR=""
  next="$(read_at "$block" "$CM" "nextOfferId()(uint256)")"
  [ "$next" -le "$MAX_OFFER_SCAN" ] || die "nextOfferId is $next, past the $MAX_OFFER_SCAN this script scans"
  for ((id = 1; id < next; id++)); do
    row="$(words "$(read_raw_at "$block" "$CM" "offerOf(uint256)" "$id")" 5)"
    read -r _ maturity apr remaining _ <<<"$row"
    [ "$maturity" = "$NOV12" ] || continue
    at_least "$remaining" "$LOAN_WEI" || continue
    if [ -z "$PICK_ID" ] || [ "$apr" -lt "$PICK_APR" ]; then
      PICK_ID="$id"
      PICK_APR="$apr"
    fi
  done
  [ -n "$PICK_ID" ] || die "no open offer at $NOV12 can lend 10 MUSD"
}

# open_loan <n>: one approval and one lockAndBorrow, in their own transactions. A refusal of 0.0004 BTC stops the run in
# the simulation inside step; the amount is never raised.
open_loan() {
  local n="$1" key="LOAN_$1" offer apr token owed value row
  if ! handled "$key"; then
    pick_offer "$(pin_block)"
    mark "${key}_OFFER" "$PICK_ID"
    mark "${key}_APR" "$PICK_APR"
  fi
  offer="$(done_value "${key}_OFFER")"
  apr="$(done_value "${key}_APR")"
  [[ "$offer" =~ ^[0-9]+$ && "$apr" =~ ^[0-9]+$ ]] || die "no offer recorded for seed loan $n"
  step "${key}_APPROVE" "BTC.approve(LoanManager, 0.0004 BTC) for seed loan $n" BORROWER_2 "$GAS_APPROVE" \
    "$BTC" "approve(address,uint256)" "$LM" "$LOCK_BTC_WEI"
  step "$key" "LoanManager.lockAndBorrow(0.0004 BTC, $LOCK_SECONDS s, $NOV12, [$offer], [10 MUSD], $apr) seed loan $n" \
    BORROWER_2 "$GAS_LOCK_BORROW" \
    "$LM" "lockAndBorrow(uint256,uint256,uint64,uint256[],uint128[],uint16)" \
    "$LOCK_BTC_WEI" "$LOCK_SECONDS" "$NOV12" "[$offer]" "[$LOAN_WEI]" "$apr"
  remember "${key}_TOKEN" event_value "$SENT_HASH" "$LM" "Deposited(uint256,address)" 1
  token="$(done_value "${key}_TOKEN")"
  [[ "$token" =~ ^[0-9]+$ ]] || die "no tokenId recorded for seed loan $n"
  owed="$(read_at "$SENT_BLOCK" "$LM" "owedOf(uint256)(uint256)" "$token")"
  row="$(words "$(read_raw_at "$SENT_BLOCK" "$LM" "collateralValue(uint256)" "$token")" 2)"
  read -r _ value <<<"$row"
  echo "   veBTC #$token from offer $offer at $apr bps: owed $(shown "$owed") MUSD, collateral worth $(shown "$value") MUSD"
  at_least "$value" "$owed" || die "C80: #$token's collateral is worth less than its debt"
}

read_position() {
  local raw
  raw="$(read_raw_at "$2" "$LM" "positionOf(uint256)" "$1")"
  POS_BORROWER="0x${raw:26:40}"
  POS_OPERATOR="0x${raw:90:40}"
}

echo "== Step 2: the deployer swaps 0.0105 BTC for at least 800 MUSD"
step APPROVE_SWAP "BTC.approve(Router, 0.0105 BTC)" DEPLOYER "$GAS_APPROVE" \
  "$BTC" "approve(address,uint256)" "$ROUTER" "$SWAP_BTC_WEI"
SWAP_DEADLINE=0
if ! handled SWAP; then
  SWAP_NOW="$(block_time "$(pin_block)")"
  SWAP_DEADLINE=$((SWAP_NOW + SWAP_DEADLINE_SECONDS))
fi
step SWAP "Router.swapExactTokensForTokens(0.0105 BTC, min 800 MUSD, BTC to MUSD volatile)" DEPLOYER "$GAS_SWAP" \
  "$ROUTER" "swapExactTokensForTokens(uint256,uint256,(address,address,bool,address)[],address,uint256)" \
  "$SWAP_BTC_WEI" "$SWAP_MIN_WEI" "[($BTC,$MUSD,false,$FACTORY)]" "$DEPLOYER" "$SWAP_DEADLINE"
remember SWAP_OUT event_value "$SENT_HASH" "$MUSD" "Transfer(address,address,uint256)" d0
echo "   the swap paid $(shown "$(done_value SWAP_OUT)") MUSD"
at_least "$(done_value SWAP_OUT)" "$SWAP_MIN_WEI" || die "the swap paid under the 800 MUSD minimum"

echo "== Step 3: the deployer fills the Faucet with 750 MUSD and 0.03 BTC"
step FAUCET_MUSD "MUSD.transfer(Faucet, 750 MUSD)" DEPLOYER "$GAS_TRANSFER" \
  "$MUSD" "transfer(address,uint256)" "$FAUCET" "$FAUCET_MUSD_WEI"
step FAUCET_BTC "send 0.03 BTC to the Faucet" DEPLOYER "$GAS_VALUE" "$FAUCET" --value "$FAUCET_BTC_WEI"
faucet_report "$(pin_block)"

echo "== Step 4: the deployer posts a parked 40 MUSD offer on each open Thursday"
handled APPROVE_OFFERS || mark APPROVE_OFFERS_SHOWN "$(shown "$OFFERS_WEI")"
if handled APPROVE_OFFERS || [ "$OFFERS_WEI" != "0" ]; then
  step APPROVE_OFFERS "MUSD.approve(CreditMarkets, $(done_value APPROVE_OFFERS_SHOWN) MUSD)" DEPLOYER "$GAS_APPROVE" \
    "$MUSD" "approve(address,uint256)" "$CM" "$OFFERS_WEI"
fi
for i in "${!OFFER_DATES[@]}"; do
  date="${OFFER_DATES[$i]}"
  apr="${OFFER_APRS[$i]}"
  key="OFFER_$date"
  if [ -n "$(done_value "${key}_SKIPPED")" ]; then
    echo "   SKIPPED $date: $(done_value "${key}_SKIPPED")"
    continue
  fi
  step "$key" "CreditMarkets.postParkedOffer($date, $apr, 40 MUSD)" DEPLOYER "$GAS_POST" \
    "$CM" "postParkedOffer(uint64,uint16,uint128)" "$date" "$apr" "$OFFER_WEI"
  remember "${key}_ID" event_value "$SENT_HASH" "$CM" "OfferPosted(uint256,address,uint64,uint16,uint128)" 1
  echo "   offer $(done_value "${key}_ID") posted for $date at $apr bps"
done

echo "== Step 5: the deployer funds BORROWER_2"
step FUND_BORROWER_2 "send 0.0016 BTC to BORROWER_2" DEPLOYER "$GAS_VALUE" "$BORROWER_2" --value "$BORROWER_2_BTC_WEI"

echo "== Step 6: BORROWER_2 opens three 10 MUSD loans due 12 Nov on 0.0004 BTC each, left unpaid on purpose"
for n in $(seq 1 "$LOAN_COUNT"); do
  open_loan "$n"
done

echo "== Step 7: the borrower repays #$LARGE_LOAN in full, so that position stays out of the 12 Nov auctions"
PIN="$(pin_block)"
read_position "$LARGE_LOAN" "$PIN"
[ "$(lower "$POS_BORROWER")" = "$(lower "$BORROWER")" ] || die "#$LARGE_LOAN's borrower reads $POS_BORROWER, not $BORROWER"
LARGE_OWED="$(read_at "$PIN" "$LM" "owedOf(uint256)(uint256)" "$LARGE_LOAN")"
echo "   owedOf($LARGE_LOAN) reads $(shown "$LARGE_OWED") MUSD at block $PIN"
if handled REPAY || [ "$LARGE_OWED" != "0" ]; then
  # Owed only falls, so an approval left from a stopped run still covers this repayment.
  step REPAY_APPROVE "MUSD.approve(LoanManager, exactly what #$LARGE_LOAN owes) by the borrower" BORROWER "$GAS_APPROVE" \
    "$MUSD" "approve(address,uint256)" "$LM" "$LARGE_OWED"
  step REPAY "LoanManager.repay($LARGE_LOAN, all it owes) by the borrower" BORROWER "$GAS_REPAY" \
    "$LM" "repay(uint256,uint256)" "$LARGE_LOAN" "$LARGE_OWED"
else
  echo "   #$LARGE_LOAN already owes nothing, so no repayment was sent"
fi
LAST_BLOCK="$SENT_BLOCK"

echo "== Step 8: the seed record"
OFFER_ROWS=()
for i in "${!OFFER_DATES[@]}"; do
  date="${OFFER_DATES[$i]}"
  id="$(done_value "OFFER_${date}_ID")"
  [ -z "$id" ] || OFFER_ROWS+=("$id:$date:${OFFER_APRS[$i]}:$OFFER_WEI")
done
LOAN_ROWS=()
for n in $(seq 1 "$LOAN_COUNT"); do
  LOAN_ROWS+=("$(done_value "LOAN_${n}_TOKEN"):$BORROWER_2:$NOV12:$(done_value "LOAN_${n}_HASH")")
done
"$PY" -I -c '
import json, sys
path, chain, block, date, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
rows = sys.argv[6:]
offers = []
for row in rows[:count]:
    offer_id, maturity, apr, amount = row.split(":")
    offers.append({"id": int(offer_id), "maturity": int(maturity), "aprBps": int(apr), "amount": amount})
loans = []
for row in rows[count:]:
    token, borrower, maturity, tx = row.split(":")
    loans.append({"tokenId": int(token), "borrower": borrower, "maturity": int(maturity), "hash": tx})
record = {"chainId": chain, "offers": offers, "auctionLoans": loans, "seedAuctionDates": [date], "block": block}
with open(path, "w", newline="\n") as out:
    json.dump(record, out, indent=2)
    out.write("\n")
' "$(native_path "$CONTRACTS_DIR/$SEED_RECORD")" "$CHAIN_ID" "$LAST_BLOCK" "$NOV12" "${#OFFER_ROWS[@]}" \
  "${OFFER_ROWS[@]}" "${LOAN_ROWS[@]}"
echo "   wrote $SEED_RECORD, last block $LAST_BLOCK"

PIN="$(pin_block)"
echo "== Where things stand, read at block $PIN"
faucet_report "$PIN"
for date in "${OFFER_DATES[@]}"; do
  if [ -n "$(done_value "OFFER_${date}_SKIPPED")" ]; then
    echo "   offer for $date: SKIPPED, $(done_value "OFFER_${date}_SKIPPED")"
    continue
  fi
  id="$(done_value "OFFER_${date}_ID")"
  row="$(words "$(read_raw_at "$PIN" "$CM" "offerOf(uint256)" "$id")" 5)"
  read -r _ maturity apr remaining _ <<<"$row"
  [ "$maturity" = "$date" ] || die "offer $id reads maturity $maturity, not $date"
  echo "   offer $id for $date at $apr bps: $(shown "$remaining") MUSD remaining"
done
for n in $(seq 1 "$LOAN_COUNT"); do
  token="$(done_value "LOAN_${n}_TOKEN")"
  owed="$(read_at "$PIN" "$LM" "owedOf(uint256)(uint256)" "$token")"
  row="$(words "$(read_raw_at "$PIN" "$LM" "lockOf(uint256)" "$token")" 2)"
  read -r lock_amount lock_end <<<"$row"
  [ "$lock_amount" = "$LOCK_BTC_WEI" ] || die "#$token locks $lock_amount, not $LOCK_BTC_WEI"
  [ "$lock_end" -ge "$NOV12" ] || die "#$token's lock ends at $lock_end, before its maturity"
  [ "$owed" != "0" ] || die "#$token owes nothing, so it will not reach auction"
  echo "   seed loan $n, veBTC #$token: owedOf $(shown "$owed") MUSD, lock $(shown "$lock_amount") BTC until $lock_end"
done
LARGE_OWED="$(read_at "$PIN" "$LM" "owedOf(uint256)(uint256)" "$LARGE_LOAN")"
LARGE_OWNER="$(read_at "$PIN" "$VEBTC" "ownerOf(uint256)(address)" "$LARGE_LOAN")"
read_position "$LARGE_LOAN" "$PIN"
echo "   owedOf($LARGE_LOAN) = $LARGE_OWED"
echo "   veBTC #$LARGE_LOAN: held by $LARGE_OWNER, borrower $POS_BORROWER, reward operator $POS_OPERATOR"
[ "$LARGE_OWED" = "0" ] || die "#$LARGE_LOAN still owes $(shown "$LARGE_OWED") MUSD"
[ "$(lower "$LARGE_OWNER")" = "$(lower "$LM")" ] || die "#$LARGE_LOAN left custody; it is held by $LARGE_OWNER"
[ "$(lower "$POS_BORROWER")" = "$(lower "$BORROWER")" ] || die "#$LARGE_LOAN's borrower reads $POS_BORROWER, not $BORROWER"
[ "$(lower "$POS_OPERATOR")" = "$(lower "$PD")" ] || die "#$LARGE_LOAN's reward operator reads $POS_OPERATOR, not PayDown $PD"

echo "== Nonces"
# Reads until a lagging node has caught up with this run's sends, so a mismatch means someone else used the wallet.
settled_nonce() {
  local n
  for _ in $(seq 1 "$WAIT_TRIES"); do
    n="$(fresh_nonce "$1")"
    [ "$n" -ge "$2" ] && break
    sleep "$WAIT_SECONDS"
  done
  echo "$n"
}
for who in "${SIGNERS[@]}"; do
  nonce_var="${who}_NONCE"
  start_var="${who}_START_NONCE"
  end_nonce="$(settled_nonce "${!who}" "${!nonce_var}")"
  echo "   $who: $end_nonce now, ${!start_var} when this run started"
  [ "$end_nonce" = "${!nonce_var}" ] || die "$who's nonce reads $end_nonce, expected ${!nonce_var}"
done
echo "   transactions sent this run: $SENT_THIS_RUN"

echo "   transactions:"
while IFS='|' read -r label hash block gas_used; do
  echo "     $label: $hash (block $block, gas $gas_used)"
done < "$TX_LOG"
echo "Quest seed set up on Mezo testnet"
