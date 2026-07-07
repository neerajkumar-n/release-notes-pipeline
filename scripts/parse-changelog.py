#!/usr/bin/env python3
"""Parse juspay/hyperswitch's CHANGELOG.md into structured entries for a date range.

Changelog shape:
  ## 2026.06.24.0
  ### Features
  - **scope:** Description ([#123](.../pull/123)) ([`hash`](.../commit/hash))
  - **scope:**
    - Sub-entry description ([#124](.../pull/124)) ([`hash`](...))
"""
import json
import re
import sys

VERSION_RE = re.compile(r"^## ((\d{4}\.\d{2}\.\d{2})\.\d+)")
CATEGORY_RE = re.compile(r"^### (.+)")
TOP_BULLET_RE = re.compile(r"^- (.*)$")
SUB_BULLET_RE = re.compile(r"^  - (.*)$")
SCOPE_RE = re.compile(r"^\*\*([^*]+)\*\*\s*(.*)$")
PR_LINK_RE = re.compile(r"\[#(\d+)\]\(https://github\.com/juspay/hyperswitch/pull/(\d+)\)")
COMMIT_LINK_RE = re.compile(r"\(\[`[0-9a-f]+`\]\([^)]*\)\)")


def clean_description(text):
    text = COMMIT_LINK_RE.sub("", text)
    text = PR_LINK_RE.sub("", text)
    text = re.sub(r"\(\s*\)", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def extract_prs(text):
    matches = PR_LINK_RE.findall(text)
    numbers = [int(m[1]) for m in matches]
    links = [f"https://github.com/juspay/hyperswitch/pull/{m[1]}" for m in matches]
    return numbers, links


def parse(changelog_text, start_date, end_date):
    entries = []
    current_version = None
    current_date = None
    in_range = False
    current_category = None
    current_scope = None

    for line in changelog_text.splitlines():
        version_match = VERSION_RE.match(line)
        if version_match:
            current_version = version_match.group(1)
            current_date = version_match.group(2).replace(".", "-")
            in_range = start_date <= current_date <= end_date
            current_category = None
            current_scope = None
            continue

        if not in_range:
            continue

        category_match = CATEGORY_RE.match(line)
        if category_match:
            current_category = category_match.group(1).strip()
            current_scope = None
            continue

        sub_match = SUB_BULLET_RE.match(line)
        if sub_match and current_scope:
            numbers, links = extract_prs(sub_match.group(1))
            if numbers:
                entries.append({
                    "version": current_version,
                    "date": current_date,
                    "category": current_category,
                    "scope": current_scope,
                    "description": clean_description(sub_match.group(1)),
                    "prNumbers": numbers,
                    "prLinks": links,
                })
            continue

        top_match = TOP_BULLET_RE.match(line)
        if top_match:
            text = top_match.group(1)
            scope_match = SCOPE_RE.match(text)
            if scope_match:
                current_scope = scope_match.group(1).rstrip(":").strip()
                rest = scope_match.group(2).strip()
            else:
                current_scope = None
                rest = text

            if rest:
                numbers, links = extract_prs(rest)
                if numbers:
                    entries.append({
                        "version": current_version,
                        "date": current_date,
                        "category": current_category,
                        "scope": current_scope,
                        "description": clean_description(rest),
                        "prNumbers": numbers,
                        "prLinks": links,
                    })

    return entries


def main():
    if len(sys.argv) != 5:
        print("Usage: parse-changelog.py <changelog_path> <output_path> <start_date> <end_date>", file=sys.stderr)
        sys.exit(1)

    changelog_path, output_path, start_date, end_date = sys.argv[1:5]

    with open(changelog_path, "r") as f:
        text = f.read()

    entries = parse(text, start_date, end_date)

    with open(output_path, "w") as f:
        json.dump(entries, f, indent=2)

    pr_total = len({n for e in entries for n in e["prNumbers"]})
    print(f"Parsed {len(entries)} changelog entries covering {pr_total} unique PR(s) "
          f"between {start_date} and {end_date}")


if __name__ == "__main__":
    main()
