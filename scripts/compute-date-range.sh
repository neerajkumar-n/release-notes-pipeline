#!/usr/bin/env bash
# Computes the most recent Wednesday-to-Wednesday date range.
# Outputs two lines: START (previous Wednesday) and END (most recent Wednesday).
#
# When run on a Wednesday (the scheduled cron day), END = today, START = 7 days ago.
# When run on any other day, snaps back to the most recent Wednesday boundary
# so the range is always Wed→Wed regardless of when the script is invoked.
#
# Works on macOS (date -v) and Linux (date -d).

set -euo pipefail

DOW=$(date +%u)  # 1=Monday, 2=Tuesday, 3=Wednesday, ..., 7=Sunday

if [ "$DOW" -ge 3 ]; then
  DAYS_BACK=$((DOW - 3))
else
  DAYS_BACK=$((DOW + 4))
fi

END_OFFSET=$DAYS_BACK
START_OFFSET=$((DAYS_BACK + 7))

END=$(date -v-${END_OFFSET}d +%Y-%m-%d 2>/dev/null || date -d "${END_OFFSET} days ago" +%Y-%m-%d)
START=$(date -v-${START_OFFSET}d +%Y-%m-%d 2>/dev/null || date -d "${START_OFFSET} days ago" +%Y-%m-%d)

echo "$START"
echo "$END"
