#!/usr/bin/env bash
# Local end-to-end test for the weekly PR summary pipeline.
# Usage:
#   ./scripts/test-local.sh          # run all stages
#   ./scripts/test-local.sh fetch    # stage 1 only
#   ./scripts/test-local.sh summarize # stage 2 only
#   ./scripts/test-local.sh publish  # stage 3 only (Markdown→JSON, no Sanity unless token set)
#
# Export these environment variables before running (or pass inline):
#   AI_MODEL_URL        — OpenAI-compatible chat completions endpoint
#   AI_MODEL_API_KEY    — API key for the endpoint
#   AI_MODEL_NAME       — Model name (default: gemini-3-flash-preview)
#   SANITY_WRITE_TOKEN  — Sanity Editor token (only needed for publish)
#   SANITY_PROJECT_ID   — Sanity project ID (default: 5ybiq59b)
#   SANITY_DATASET      — Sanity dataset (default: production)
#   START_DATE / END_DATE — Override date range (default: Wed-to-Wed)
#   CHUNK_SIZE          — Entries per chunk (default: 0 = single-pass)
#
# Example:
#   AI_MODEL_URL=... AI_MODEL_API_KEY=... ./scripts/test-local.sh summarize
#
# Stage 1 needs no credentials, Stage 2 needs AI vars,
# Stage 3 publish-to-Sanity needs a Sanity token.

set -euo pipefail
cd "$(dirname "$0")/.."

WORKDIR="/tmp/weekly-test"
mkdir -p "$WORKDIR"

# ── Defaults (Wednesday-to-Wednesday, snaps to most recent Wednesday) ──
if [ -z "${START_DATE:-}" ] || [ -z "${END_DATE:-}" ]; then
  _DATES=($(bash scripts/compute-date-range.sh))
  START_DATE="${START_DATE:-${_DATES[0]}}"
  END_DATE="${END_DATE:-${_DATES[1]}}"
fi
AI_MODEL_NAME="${AI_MODEL_NAME:-gemini-3-flash-preview}"
CHUNK_SIZE="${CHUNK_SIZE:-0}"

STAGE="${1:-all}"

# ── System prompt (must match workflow) ──
SYSTEM_PROMPT='You are a technical writer producing weekly release notes for Hyperswitch (hyperswitch.io).

CRITICAL RULES:
1. EVERY SINGLE entry from the input MUST appear in the output. No exceptions.
2. EVERY bullet point in EVERY section (including Highlights) MUST use this EXACT format:
   - **Label** — Description sentence(s). [(#NUMBER)](https://github.com/juspay/hyperswitch/pull/NUMBER)
   The bold "Label —" prefix is REQUIRED on every bullet, not just in Highlights.
   If an entry has multiple PR numbers, include all of them as separate trailing links.
3. Group related entries under one bullet when they share a theme/connector
4. Test coverage entries belong in their appropriate section

STRUCTURE:

## Highlights
Identify the 2-5 most important themes of the week. Each theme is ONE bullet with:
- A bold theme label: **Theme Name** —
- Followed by 1-2 sentences summarizing the impact

## Connectors
Payment processor integrations, connector features, connector fixes, AND connector test coverage.
- One bullet per entry or related group, formatted as: **Label** — 1-2 sentence description
- MUST end with: [(#N)](https://github.com/juspay/hyperswitch/pull/N)

## Customer & Access Management
Authentication, payment methods, vault, customer data, merchant profiles.
- One bullet per entry or related group, formatted as: **Label** — 1-2 sentence description
- MUST end with: [(#N)](https://github.com/juspay/hyperswitch/pull/N)

## Routing & Core Improvements
Core engine, routing, infrastructure, performance, refactors, documentation, AND core test coverage.
- One bullet per entry or related group, formatted as: **Label** — 1-2 sentence description
- MUST end with: [(#N)](https://github.com/juspay/hyperswitch/pull/N)

STRICT REQUIREMENTS:
- ALL entries must be covered
- No PR numbers in bullet text — only in the link at the end
- No author names, no merge dates
- Active voice, present tense
- Do not invent changes
- Output ONLY Markdown'

fetch_entries() {
  echo "=== Stage 1: Fetch & Parse Changelog ==="
  echo "Date range: ${START_DATE} → ${END_DATE}"
  echo ""

  curl -sfS "https://raw.githubusercontent.com/juspay/hyperswitch/main/CHANGELOG.md" \
    -o "${WORKDIR}/changelog.md"
  echo "Downloaded changelog ($(wc -l < "${WORKDIR}/changelog.md") lines)"

  python3 scripts/parse-changelog.py \
    "${WORKDIR}/changelog.md" "${WORKDIR}/entries.json" \
    "${START_DATE}" "${END_DATE}"

  local count
  count=$(jq 'length' "${WORKDIR}/entries.json")
  echo ""
  echo "Parsed ${count} entries"

  if [ "${count}" -eq 0 ]; then
    echo "No entries in range — nothing to summarize."
    exit 0
  fi

  echo ""
  echo "By category:"
  jq -r 'group_by(.category) | .[] | "  \(length) — \(.[0].category)"' "${WORKDIR}/entries.json"
  echo ""
  echo "Output: ${WORKDIR}/entries.json"
}

summarize() {
  echo "=== Stage 2: Summarize with AI ==="
  local entry_data total
  entry_data=$(cat "${WORKDIR}/entries.json")
  total=$(echo "${entry_data}" | jq 'length')
  echo "Sending ${total} entries to AI model: ${AI_MODEL_NAME}"
  echo ""

  if [ -z "${AI_MODEL_URL:-}" ]; then
    echo "ERROR: AI_MODEL_URL is not set. Export it before running:"
    echo "  AI_MODEL_URL=... AI_MODEL_API_KEY=... ./scripts/test-local.sh summarize"
    exit 1
  fi

  local payload response summary
  payload=$(jq -n \
    --arg system "${SYSTEM_PROMPT}" \
    --arg user "Weekly changelog entries (${total} total):\n\n${entry_data}" \
    '{model: env.AI_MODEL_NAME, messages: [{role: "system", content: $system}, {role: "user", content: $user}], temperature: 0.2}')

  response=$(curl -sfS \
    -H "Authorization: Bearer ${AI_MODEL_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${AI_MODEL_URL}")

  summary=$(echo "${response}" | jq -r '.choices[0].message.content')

  if [ -z "${summary}" ] || [ "${summary}" = "null" ]; then
    echo "ERROR: Empty summary from AI"
    exit 1
  fi

  echo "${summary}" > "${WORKDIR}/summary.md"
  echo "Summary saved: ${WORKDIR}/summary.md ($(echo "${summary}" | wc -w | tr -d ' ') words)"
  echo ""
  echo "--- Preview (first 30 lines) ---"
  head -30 "${WORKDIR}/summary.md"
}

publish() {
  echo "=== Stage 3: Convert Markdown → JSON ==="

  if [ ! -f "${WORKDIR}/summary.md" ]; then
    echo "ERROR: ${WORKDIR}/summary.md not found — run 'summarize' first."
    exit 1
  fi

  WEEK_START="${START_DATE}" WEEK_END="${END_DATE}" \
    PR_COUNT=$(jq '[.[].prNumbers[]] | unique | length' "${WORKDIR}/entries.json") \
    bash scripts/parse-markdown-to-json.sh "${WORKDIR}/summary.md"

  cp "${WORKDIR}/summary.json" "${WORKDIR}/summary.json" 2>/dev/null || true
  echo ""
  echo "JSON saved: ${WORKDIR}/summary.json"
  echo ""
  echo "--- JSON preview ---"
  jq '{weekStart, weekEnd, prCount, highlights: (.highlights|length), sections: ([.[] | select(type=="array")] | length)}' \
    "${WORKDIR}/summary.json"

  # ── Push to Sanity (optional, only if token is set) ──
  if [ -n "${SANITY_WRITE_TOKEN:-}" ]; then
    echo ""
    echo "=== Stage 3b: Push to Sanity ==="
    if [ ! -d node_modules/@sanity/client ]; then
      echo "Installing @sanity/client..."
      npm install @sanity/client@^6
    fi
    SANITY_WRITE_TOKEN="${SANITY_WRITE_TOKEN}" \
    SANITY_PROJECT_ID="${SANITY_PROJECT_ID:-5ybiq59b}" \
    SANITY_DATASET="${SANITY_DATASET:-production}" \
      node scripts/push-to-sanity.mjs "${WORKDIR}/summary.json"
  else
    echo ""
    echo "Skipping Sanity push — SANITY_WRITE_TOKEN is not set."
    echo "To push, export it and re-run: SANITY_WRITE_TOKEN=... ./scripts/test-local.sh publish"
  fi
}

case "${STAGE}" in
  fetch)     fetch_entries ;;
  summarize) summarize ;;
  publish)   publish ;;
  all)
    fetch_entries
    echo ""
    summarize
    echo ""
    publish
    ;;
  *)
    echo "Usage: $0 {fetch|summarize|publish|all}"
    exit 1
    ;;
esac

echo ""
echo "Done. All artifacts in: ${WORKDIR}"
