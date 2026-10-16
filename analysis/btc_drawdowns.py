"""Bitcoin drawdown study that sets Doji's borrow limit, liquidation line and auction terms.

    python -I analysis/btc_drawdowns.py                run the study on the cached prices
    python -I analysis/btc_drawdowns.py --fetch        download daily prices once and cache them
    python -I analysis/btc_drawdowns.py --fetch --source kraken --out some.csv

Standard library only. The study reads analysis/data/btc_daily.csv.
"""

import argparse
import csv
import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_DATA = HERE / "data" / "btc_daily.csv"
COLUMNS = ["date_utc", "open", "high", "low", "close", "volume"]

BINANCE_URL = "https://api.binance.com/api/v3/klines"
KRAKEN_URL = "https://api.kraken.com/0/public/OHLC"

BREACH_DAYS = 28
EXIT_DAYS = 35
RECENT_YEARS = 4
PERCENTILES = (99.9, 99.0, 95.0)
MAX_LTVS = (35, 40, 45, 50, 55, 60)
LIQ_LTVS = (55, 60, 65, 70, 75)
HORIZON_GROUPS = (
    ("auction length", (1, 2, 3, 4, 5)),
    ("loan and exit", (7, 14, 21, 28, 35)),
    ("longest loan plus exit", (BREACH_DAYS + EXIT_DAYS,)),
)
SHOWN_PAIRS = ((35, 65), (40, 65), (45, 65), (50, 65))
SENSITIVITY_EXITS = (35, 38, 42)
EPISODE_GAP_DAYS = 7


def http_get_json(url, retries=4):
    request = urllib.request.Request(url, headers={"User-Agent": "doji-risk-study/1.0"})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            if attempt == retries - 1:
                raise
            time.sleep(2**attempt)


def utc_date(seconds):
    return datetime.fromtimestamp(seconds, tz=timezone.utc).date().isoformat()


def fetch_binance():
    rows = []
    start_ms = 0
    now_ms = int(time.time() * 1000)
    while True:
        query = urllib.parse.urlencode(
            {"symbol": "BTCUSDT", "interval": "1d", "startTime": start_ms, "limit": 1000}
        )
        page = http_get_json(f"{BINANCE_URL}?{query}")
        if not page:
            break
        for candle in page:
            open_ms, close_ms = candle[0], candle[6]
            if close_ms >= now_ms:
                continue
            rows.append([utc_date(open_ms / 1000), candle[1], candle[2], candle[3], candle[4], candle[5]])
        if len(page) < 1000:
            break
        start_ms = page[-1][0] + 1
        time.sleep(0.25)
    source = {
        "source": "Binance spot public API, BTCUSDT, 1d candles in UTC, no API key",
        "endpoint": BINANCE_URL,
        "note": "prices are Bitcoin quoted in USDT (a dollar stablecoin), not USD",
    }
    return rows, source


def fetch_kraken():
    query = urllib.parse.urlencode({"pair": "XBTUSD", "interval": 1440})
    payload = http_get_json(f"{KRAKEN_URL}?{query}")
    if payload.get("error"):
        raise RuntimeError(f"Kraken returned {payload['error']}")
    key = next(name for name in payload["result"] if name != "last")
    now = time.time()
    rows = []
    for candle in payload["result"][key]:
        if candle[0] + 86400 > now:
            continue
        rows.append([utc_date(candle[0]), candle[1], candle[2], candle[3], candle[4], candle[6]])
    source = {
        "source": "Kraken spot public API, XBT/USD, 1d candles in UTC, no API key",
        "endpoint": KRAKEN_URL,
        "note": "Kraken serves only the latest 720 daily candles, so this history is short",
    }
    return rows, source


def write_csv(path, rows, source):
    rows = sorted({row[0]: row for row in rows}.values())
    path.parent.mkdir(parents=True, exist_ok=True)
    fetched = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    with open(path, "w", newline="", encoding="utf-8") as handle:
        handle.write("# Doji risk study: Bitcoin daily prices\n")
        handle.write(f"# source: {source['source']}\n")
        handle.write(f"# endpoint: {source['endpoint']}\n")
        handle.write(f"# fetched: {fetched}\n")
        handle.write(f"# range: {rows[0][0]} to {rows[-1][0]}, {len(rows)} daily rows, the unfinished current day is excluded\n")
        handle.write(f"# note: {source['note']}\n")
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(COLUMNS)
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows, {rows[0][0]} to {rows[-1][0]}, to {path}")


def run_fetch(args):
    sources = {"binance": fetch_binance, "kraken": fetch_kraken}
    order = [args.source] if args.source else ["binance", "kraken"]
    for name in order:
        try:
            rows, source = sources[name]()
        except (urllib.error.URLError, TimeoutError, RuntimeError, json.JSONDecodeError) as err:
            print(f"{name} failed: {err}", file=sys.stderr)
            continue
        write_csv(Path(args.out), rows, source)
        return 0
    print("no source could be reached", file=sys.stderr)
    return 1


def load_prices(path):
    header = {}
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    for line in lines:
        if line.startswith("# ") and ": " in line:
            key, value = line[2:].split(": ", 1)
            header[key] = value
    table = list(csv.DictReader(line for line in lines if not line.startswith("#")))
    days = [date.fromisoformat(row["date_utc"]) for row in table]
    closes = [float(row["close"]) for row in table]
    lows = [float(row["low"]) for row in table]
    missing = (days[-1] - days[0]).days + 1 - len(days)
    if missing or days != sorted(set(days)):
        raise SystemExit(f"price file has {missing} missing days or unsorted dates; refetch it")
    return header, days, closes, lows


def percentile(sorted_values, pct):
    rank = math.ceil(round(pct * len(sorted_values) / 100, 9))
    return sorted_values[max(rank, 1) - 1]


def drawdown_windows(closes, troughs, horizon):
    """Largest fall in each window of `horizon` days, from a closing peak to a later day's trough."""
    results = []
    for first in range(len(closes) - horizon):
        peak = 0.0
        peak_at = first
        best = (0.0, first, first)
        for k in range(first + 1, first + horizon + 1):
            if closes[k - 1] > peak:
                peak = closes[k - 1]
                peak_at = k - 1
            fall = 1.0 - troughs[k] / peak
            if fall > best[0]:
                best = (fall, peak_at, k)
        results.append(best)
    return results


def point_to_point_falls(closes, horizon):
    return [1.0 - closes[i + horizon] / closes[i] for i in range(len(closes) - horizon)]


def summarise(values):
    ordered = sorted(values)
    return [ordered[-1]] + [percentile(ordered, p) for p in PERCENTILES]


def pct(value, places=1):
    return f"{100 * value:.{places}f}%"


def stat_cells(stats):
    return " ".join(f"{pct(v):>7}" for v in stats)


def stats_header(title):
    print(f"\n{title}")
    print(f"{'days':>5} | {'ALL HISTORY':^31} | {'LAST 4 YEARS':^31}")
    labels = " ".join(f"{name:>7}" for name in ("worst", "99.9th", "99th", "95th"))
    print(f"{'':>5} | {labels} | {labels}")


def group_divider(label):
    print(f"{'-' * 5}-+-{'-' * 31}-+-{'-' * 31}   {label}")


def drawdown_table(title, days, closes, troughs, recent_from, show_worst_for):
    stats_header(title)
    worst_lines = []
    for label, horizons in HORIZON_GROUPS:
        group_divider(label)
        for horizon in horizons:
            windows = drawdown_windows(closes, troughs, horizon)
            recent = windows[recent_from:]
            print(f"{horizon:>5} | {stat_cells(summarise([w[0] for w in windows]))}"
                  f" | {stat_cells(summarise([w[0] for w in recent]))}")
            if horizon in show_worst_for:
                for name, subset in (("all history", windows), ("last 4 years", recent)):
                    fall, peak_at, trough_at = max(subset)
                    worst_lines.append(
                        f"  {horizon:>2}d {name:<12}: peak close {days[peak_at]} ${closes[peak_at]:,.0f}"
                        f" -> trough {days[trough_at]} ${troughs[trough_at]:,.0f} ({pct(fall)})"
                    )
    print("windows per horizon: (days in file - horizon) for all history; those starting on or after the cutoff for 4 years")
    print(f"  example, 35 days: all history {len(days) - 35}, last 4 years {len(days) - 35 - recent_from}")
    print("worst windows found:")
    print("\n".join(worst_lines))


def point_to_point_table(closes, recent_from):
    stats_header("3. Net fall from one close to the close N days later "
                 "(what a buyer who holds a bought position for N days would lose)")
    for label, horizons in HORIZON_GROUPS:
        group_divider(label)
        for horizon in horizons:
            falls = point_to_point_falls(closes, horizon)
            print(f"{horizon:>5} | {stat_cells(summarise(falls))} | {stat_cells(summarise(falls[recent_from:]))}")


def loan_paths(closes, prices, exit_days):
    """For each opening day, the later prices as a fraction of the opening close."""
    length = BREACH_DAYS + exit_days
    paths = []
    for first in range(len(closes) - length):
        base = closes[first]
        paths.append([prices[k] / base for k in range(first + 1, first + length + 1)])
    return paths


def judge_loan(path, max_ltv, liq_ltv, exit_days):
    """Returns (breached, loss_after_breach, loss_after_unpaid_maturity, shortfall_fraction_of_debt)."""
    line = max_ltv / liq_ltv
    for k in range(BREACH_DAYS):
        if path[k] < line:
            low = min(path[k : k + exit_days + 1])
            return True, low < max_ltv, False, max(0.0, 1.0 - low / max_ltv)
    low = min(path[BREACH_DAYS : BREACH_DAYS + exit_days])
    return False, False, low < max_ltv, max(0.0, 1.0 - low / max_ltv)


def pair_counts(paths, max_ltv, liq_ltv, exit_days):
    breached = loss = default_loss = 0
    for path in paths:
        hit, lost, defaulted, _ = judge_loan(path, max_ltv, liq_ltv, exit_days)
        breached += hit
        loss += lost
        default_loss += defaulted
    return breached, loss, default_loss


def pair_table(title, paths, recent_from):
    recent = paths[recent_from:]
    print(f"\n{title}")
    print(f"loans simulated: all history {len(paths)}, last 4 years {len(recent)} (one loan opened per day)")
    print("breach = share of loans opened at maxLTV whose debt goes above the liquidation line within 28 days")
    print("loss   = breach, then the BTC value is below the debt within 35 days of the breach")
    print("loss+d = loss, or no breach but the borrower leaves the loan unpaid at day 28 and the value")
    print("         is below the debt within the 35 days after that")
    cols = f"{'breach':>7} {'loss':>7} {'loss+d':>7}"
    print(f"{'maxLTV':>6} {'liq':>4} {'cushion':>7} | {'ALL HISTORY':^23} | {'LAST 4 YEARS':^23}")
    print(f"{'':>6} {'':>4} {'':>7} | {cols} | {cols}")
    for max_ltv in MAX_LTVS:
        for liq_ltv in LIQ_LTVS:
            if max_ltv >= liq_ltv:
                continue
            cells = []
            for subset in (paths, recent):
                b, l, d = pair_counts(subset, max_ltv / 100, liq_ltv / 100, EXIT_DAYS)
                n = len(subset)
                cells.append(f"{pct(b / n, 2):>7} {pct(l / n, 2):>7} {pct((l + d) / n, 2):>7}")
            cushion = pct(1 - max_ltv / liq_ltv)
            print(f"{max_ltv:>5}% {liq_ltv:>3}% {cushion:>7} | {cells[0]} | {cells[1]}")


def episodes(days, paths, max_ltv, liq_ltv):
    hits = []
    for first, path in enumerate(paths):
        _, lost, defaulted, shortfall = judge_loan(path, max_ltv / 100, liq_ltv / 100, EXIT_DAYS)
        if lost or defaulted:
            hits.append((first, shortfall))
    if not hits:
        print(f"  maxLTV {max_ltv}%, liq {liq_ltv}%: no window with a lender loss")
        return
    groups = [[hits[0]]]
    for item in hits[1:]:
        if item[0] - groups[-1][-1][0] > EPISODE_GAP_DAYS:
            groups.append([])
        groups[-1].append(item)
    print(f"  maxLTV {max_ltv}%, liq {liq_ltv}%: {len(hits)} losing loans in {len(groups)} episodes")
    for group in groups:
        worst = max(s for _, s in group)
        print(f"    opened {days[group[0][0]]} to {days[group[-1][0]]}: {len(group)} loans,"
              f" worst shortfall {pct(worst)} of the debt")


def sensitivity_table(closes, lows, recent_from):
    print("\n7. Lender loss if the exit takes longer than 35 days "
          "(38 = a 3 day auction before the 35 day path, 42 = a further week)")
    print("   loss+d as in section 4. Loans simulated differ slightly because later exits need more history.")
    cols = f"{'loss':>7} {'loss+d':>7}"
    print(f"{'maxLTV':>6} {'liq':>4} {'exit':>5} | {'CLOSES, ALL':^15} | {'CLOSES, 4 YRS':^15}"
          f" | {'LOWS, ALL':^15} | {'LOWS, 4 YRS':^15}")
    print(f"{'':>6} {'':>4} {'':>5} | {cols} | {cols} | {cols} | {cols}")
    for max_ltv, liq_ltv in SHOWN_PAIRS:
        for exit_days in SENSITIVITY_EXITS:
            cells = []
            for prices in (closes, lows):
                paths = loan_paths(closes, prices, exit_days)
                for subset in (paths, paths[recent_from:]):
                    _, l, d = pair_counts(subset, max_ltv / 100, liq_ltv / 100, exit_days)
                    n = len(subset)
                    cells.append(f"{pct(l / n, 2):>7} {pct((l + d) / n, 2):>7}")
            print(f"{max_ltv:>5}% {liq_ltv:>3}% {exit_days:>4}d | " + " | ".join(cells))


def report(path):
    header, days, closes, lows = load_prices(path)
    cutoff = days[-1] - timedelta(days=365 * RECENT_YEARS + 1)
    recent_from = next(i for i, d in enumerate(days) if d >= cutoff)

    print("BTC drawdown study for Doji")
    print(f"data file : {path.name}")
    print(f"source    : {header.get('source', 'unknown')}")
    print(f"fetched   : {header.get('fetched', 'unknown')}")
    print(f"range     : {days[0]} to {days[-1]}, {len(days)} daily closes, no missing days")
    print(f"last 4 yrs: windows and loans that start on or after {cutoff}")
    print("A window of N days spans N+1 daily closes. Percentiles use nearest rank over all windows.")
    print("Consecutive windows overlap, so the extreme percentiles describe a handful of episodes.")

    drawdown_table("1. Peak-to-trough drop of the daily close inside any window of N days",
                   days, closes, closes, recent_from,
                   show_worst_for=(1, 2, 3, 4, 5, 7, 14, 21, 28, 35, 63))
    drawdown_table("2. Same, but the trough is a later day's intraday low (stress case)",
                   days, closes, lows, recent_from, show_worst_for=(35, 63))
    point_to_point_table(closes, recent_from)

    close_paths = loan_paths(closes, closes, EXIT_DAYS)
    low_paths = loan_paths(closes, lows, EXIT_DAYS)
    pair_table("4. Loan simulation on daily closes", close_paths, recent_from)
    pair_table("5. Loan simulation on intraday lows (a loan opens at a day's close, any later low counts)",
               low_paths, recent_from)

    print("\n6. Episodes behind the lender losses, for the pairs discussed in docs/risk/parameters.md")
    for label, paths in (("daily closes", close_paths), ("intraday lows", low_paths)):
        print(f" on {label}:")
        for max_ltv, liq_ltv in SHOWN_PAIRS:
            episodes(days, paths, max_ltv, liq_ltv)

    sensitivity_table(closes, lows, recent_from)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fetch", action="store_true", help="download the daily prices and cache them")
    parser.add_argument("--source", choices=("binance", "kraken"), help="fetch from one source only")
    parser.add_argument("--out", default=str(DEFAULT_DATA), help="where --fetch writes the cache")
    parser.add_argument("--data", default=str(DEFAULT_DATA), help="price file the study reads")
    args = parser.parse_args()
    if args.fetch:
        return run_fetch(args)
    report(Path(args.data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
