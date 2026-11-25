#!/usr/bin/env python3
"""Read docs/ASC_DAILY.csv and print the post-launch trend + gate checks.

The app ships no analytics SDK on purpose (see the privacy page), so App Store
Connect is the source of truth. Fill one row per day from ASC App Analytics and
Sales and Trends, then run this weekly.

Usage:
    python3 scripts/asc_report.py                    # totals, last 7 days, gates
    python3 scripts/asc_report.py --days 14          # custom window
    python3 scripts/asc_report.py --csv docs/ASC_DAILY.csv

Gates come from docs/POST_LAUNCH_30_DAYS.md:
    conversion < 0.8%  -> tighten the free tier rather than cut the price
    downloads  < 500   -> distribution problem, not a conversion problem
    rating     < 4.3   -> fix the experience before promoting
"""
import argparse
import csv
import os
import sys
from datetime import date, timedelta

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if not row.get("date") or not row["date"][:4].isdigit():
                continue
            parsed = {"date": row["date"]}
            for key in ("impressions", "product_page_views", "downloads",
                        "proceeds_usd", "rating_count"):
                raw = (row.get(key) or "").strip()
                parsed[key] = float(raw) if raw else None
            for key in ("conversion_pct", "rating_avg", "search_share_pct",
                        "browse_share_pct", "referrer_share_pct"):
                raw = (row.get(key) or "").strip()
                parsed[key] = float(raw) if raw else None
            parsed["notes"] = row.get("notes", "")
            rows.append(parsed)
    return rows


def total(rows, key):
    vals = [r[key] for r in rows if r[key] is not None]
    return sum(vals) if vals else None


def fmt(value, suffix="", digits=0):
    if value is None:
        return "—"
    return f"{value:,.{digits}f}{suffix}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=os.path.join(ROOT, "docs", "ASC_DAILY.csv"))
    ap.add_argument("--days", type=int, default=7)
    args = ap.parse_args()

    rows = load(args.csv)
    if not rows:
        raise SystemExit(f"no data rows in {args.csv} — fill at least one day first")

    rows.sort(key=lambda r: r["date"])
    since = (date.fromisoformat(rows[-1]["date"]) - timedelta(days=args.days - 1)).isoformat()
    window = [r for r in rows if r["date"] >= since]

    print(f"{'':22s}{'all time':>12s}{'last %d days' % args.days:>16s}")
    for key, label, digits in (("impressions", "impressions", 0),
                               ("product_page_views", "page views", 0),
                               ("downloads", "downloads", 0),
                               ("proceeds_usd", "proceeds $", 2),
                               ("rating_count", "ratings", 0)):
        print(f"{label:22s}{fmt(total(rows, key), '', digits):>12s}"
              f"{fmt(total(window, key), '', digits):>16s}")

    conv_all = None
    downloads = total(rows, "downloads")
    views = total(rows, "product_page_views")
    if downloads and views:
        conv_all = downloads / views * 100
    conv_win = None
    d_win, v_win = total(window, "downloads"), total(window, "product_page_views")
    if d_win and v_win:
        conv_win = d_win / v_win * 100
    print(f"{'conversion %':22s}{fmt(conv_all, '%', 2):>12s}{fmt(conv_win, '%', 2):>16s}")

    ratings = [r["rating_avg"] for r in rows if r["rating_avg"] is not None]
    if ratings:
        print(f"{'rating avg (last)':22s}{fmt(ratings[-1], '', 2):>12s}")

    print("\nGates")
    if conv_win is not None:
        mark = "PASS" if conv_win >= 0.8 else "FAIL → tighten the free tier, do not cut the price"
        print(f"  conversion >= 0.8%   {conv_win:.2f}%   {mark}")
    if d_win is not None:
        mark = "PASS" if d_win >= 500 else "below 500 → distribution, not conversion"
        print(f"  downloads  >= 500    {d_win:.0f}     {mark}")
    if ratings:
        mark = "PASS" if ratings[-1] >= 4.3 else "below 4.3 → fix the experience first"
        print(f"  rating     >= 4.3    {ratings[-1]:.2f}    {mark}")
    if not ratings:
        print("  rating     >= 4.3    —       no ratings recorded yet")

    if len(window) < args.days:
        print(f"\nnote: {len(window)} of {args.days} days filled — trends need a full window")
    sys.exit(0)


if __name__ == "__main__":
    main()
