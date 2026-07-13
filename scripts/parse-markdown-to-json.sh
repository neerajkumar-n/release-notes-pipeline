#!/usr/bin/env bash
set -euo pipefail

# Reads a markdown summary and produces a JSON payload. Any ## section other
# than Highlights is parsed dynamically, so new AI-emitted sections (e.g.
# Payouts) are preserved without code changes.

if [ -z "${1:-}" ]; then
  INPUT_FILE="summary_output.md"
else
  INPUT_FILE="$1"
fi

if [ ! -f "$INPUT_FILE" ]; then
  echo "Input file not found: $INPUT_FILE"
  exit 1
fi

OUTPUT_FILE="${INPUT_FILE%.md}.json"

# ── Defaults: Wednesday-to-Wednesday (snaps to most recent Wednesday) ──
if [ -z "${WEEK_START:-}" ] || [ -z "${WEEK_END:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  _DATES=($(bash "${_SCRIPT_DIR}/compute-date-range.sh"))
  WEEK_START="${WEEK_START:-${_DATES[0]}}"
  WEEK_END="${WEEK_END:-${_DATES[1]}}"
fi
PR_COUNT="${PR_COUNT:-$(grep -oE '#[0-9]+' "$INPUT_FILE" | sort -u | wc -l | tr -d ' ')}"
GENERATED_AT="$(date -Iseconds)"

echo "Parsing: $INPUT_FILE"
echo "Output: $OUTPUT_FILE"

python3 <<'PYTHON_SCRIPT' - "$INPUT_FILE" "$OUTPUT_FILE" "$WEEK_START" "$WEEK_END" "$PR_COUNT" "$GENERATED_AT"
import re
import json
import sys

input_file = sys.argv[1]
output_file = sys.argv[2]
week_start = sys.argv[3]
week_end = sys.argv[4]
pr_count = int(sys.argv[5])
generated_at = sys.argv[6]

SECTION_KEY_MAP = {
    'Connectors': 'connectors',
    'Customer & Access Management': 'customerAccessManagement',
    'Routing & Core Improvements': 'routingAndCore',
}

pr_pattern = re.compile(r'\[\(?(#(\d+))\)?\]\(https://github\.com/juspay/hyperswitch/pull/(\d+)\)')

def to_camel_case(text):
    cleaned = re.sub(r"[^\w\s&]", '', text)
    words = [w for w in re.split(r'[\s&]+', cleaned) if w]
    if not words:
        return ''
    return words[0].lower() + ''.join(w.capitalize() for w in words[1:])

def heading_to_key(heading):
    return SECTION_KEY_MAP.get(heading) or to_camel_case(heading)

def parse_bullets(section_lines):
    entries = []
    bullet_pattern = re.compile(r'- \*\*(.+?)\*\*[\s]*[—\-–][\s]*(.+)')

    for line in section_lines:
        stripped = line.strip()
        match = bullet_pattern.match(stripped)
        if not match:
            continue
        label = match.group(1).strip()
        rest = match.group(2).strip()

        pr_matches = pr_pattern.findall(rest)
        pr_numbers = [int(m[1]) for m in pr_matches]
        pr_links = [f"https://github.com/juspay/hyperswitch/pull/{m[1]}" for m in pr_matches]

        desc = pr_pattern.sub('', rest).strip()
        desc = re.sub(r'[\s]*[.]+$', '', desc).strip()

        if pr_numbers:
            entries.append({
                "title": label,
                "description": desc if desc else '',
                "prNumbers": pr_numbers,
                "prLinks": pr_links,
            })
    return entries

with open(input_file, 'r') as f:
    lines = f.read().splitlines()

highlights = []
in_highlights = False
for line in lines:
    stripped = line.strip()
    if stripped == '## Highlights':
        in_highlights = True
        continue
    if in_highlights and stripped.startswith('## '):
        break
    if in_highlights and stripped.startswith('- **'):
        match = re.match(r'- \*\*(.+?)\*\*[\s]*[—\-–][\s]*(.+)', stripped)
        if match:
            theme = match.group(1).strip()
            description = match.group(2).strip()
            description = pr_pattern.sub('', description).strip()
            description = re.sub(r'[\s]*[.]+$', '', description).strip()
            if description:
                highlights.append({
                    "theme": theme,
                    "description": description,
                })

sections = {}
current_heading = None
current_lines = []

for line in lines:
    stripped = line.strip()
    if stripped.startswith('## '):
        heading = stripped[3:].strip()
        if current_heading is not None and current_heading != 'Highlights':
            sections[current_heading] = current_lines
        current_heading = heading
        current_lines = []
    elif current_heading is not None and current_heading != 'Highlights':
        current_lines.append(line)

if current_heading is not None and current_heading != 'Highlights':
    sections[current_heading] = current_lines

output = {
    "weekStart": week_start,
    "weekEnd": week_end,
    "prCount": pr_count,
    "generatedAt": generated_at,
    "highlights": highlights,
}

for heading, section_lines in sections.items():
    key = heading_to_key(heading)
    if not key:
        continue
    output[key] = parse_bullets(section_lines)

with open(output_file, 'w') as f:
    json.dump(output, f, indent=2)

section_keys = [k for k in output if k not in {'weekStart', 'weekEnd', 'prCount', 'generatedAt', 'highlights'}]
print(f"Parsed {len(highlights)} highlights")
for key in section_keys:
    print(f"   {len(output[key])} entries in '{key}'")
import os
print(f"Saved to: {output_file} ({os.path.getsize(output_file)} bytes)")
PYTHON_SCRIPT
