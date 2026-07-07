# Weekly Hyperswitch PR Summary → Sanity

A weekly GitHub Action that reads `juspay/hyperswitch`'s public
[`CHANGELOG.md`](https://github.com/juspay/hyperswitch/blob/main/CHANGELOG.md),
extracts the entries merged in the past week, summarizes them with an AI model,
and publishes the result to Sanity as a `weekly_pr_summary` document.

This runs entirely from this repository and is independent of the
Hyperswitch repo's own release cycle — it only reads a public file over HTTPS,
it never calls the GitHub API against `juspay/hyperswitch`, so **no GitHub
token or PAT is required**.

## How it works

1. **`fetch-changelog` job** — downloads `CHANGELOG.md` from
   `raw.githubusercontent.com/juspay/hyperswitch/main/CHANGELOG.md` and runs
   `scripts/parse-changelog.py` to extract entries (category, scope,
   description, PR numbers/links) whose changelog version date falls within
   the target week. The date range always aligns to **Wednesday-to-Wednesday**
   boundaries via `scripts/compute-date-range.sh`, regardless of which day the
   workflow is triggered.
2. **`summarize` job** — sends the parsed entries to an OpenAI-compatible
   chat completions endpoint with a system prompt that groups them into
   Highlights / Connectors / Customer & Access Management / Routing & Core.
3. **`publish` job** — converts the AI's Markdown into JSON
   (`scripts/parse-markdown-to-json.sh`) and pushes it to Sanity as a
   `weekly_pr_summary` document with a deterministic `_id`
   (`scripts/push-to-sanity.mjs`), so reruns are idempotent.

Runs every Wednesday at 04:30 UTC (10:00 AM IST), or on-demand via
**Actions → Weekly PR Summary to Sanity → Run workflow**, with optional
`start_date` / `end_date` overrides. The default date range is always the
most recent Wednesday-to-Wednesday period (previous Wednesday through the
most recent Wednesday).

## Required secrets

Configure under **Settings → Secrets and variables → Actions**:

| Secret | Required? | Value |
|--------|-----------|-------|
| `AI_MODEL_URL` | Yes | OpenAI-compatible chat completions endpoint |
| `AI_MODEL_API_KEY` | Yes | API key for that endpoint |
| `SANITY_WRITE_TOKEN` | Yes | Sanity **Editor**-permission token |
| `SANITY_PROJECT_ID` | No (defaults to `5ybiq59b`) | Sanity project ID |
| `SANITY_DATASET` | No (defaults to `production`) | Sanity dataset name |

Optional repository variable:

| Variable | Default |
|----------|---------|
| `AI_MODEL_NAME` | `gemini-3-flash-preview` |

No GitHub PAT is needed — `CHANGELOG.md` is fetched as a public, unauthenticated
raw file.

## Creating the Sanity token

1. Visit https://www.sanity.io/manage/project/5ybiq59b
2. **API → Tokens → Add API token**
3. Name it (e.g. `weekly-pr-summary-action`), permission **Editor**
4. Copy it into the `SANITY_WRITE_TOKEN` secret

## Testing manually

Go to **Actions → Weekly PR Summary to Sanity → Run workflow**. Leave the
inputs blank to summarize the most recent Wednesday-to-Wednesday period, or
set `start_date`/`end_date` to backfill a specific range. Expect a final
log line like:

```
Wrote weekly-pr-summary-YYYY-MM-DD — N sections, M items
```

Verify in Sanity with the query `*[_type == "weekly_pr_summary"]`.

## Security notes

- No tokens are committed to this repo; everything sensitive lives in
  GitHub Secrets.
- The Sanity token should have **Editor** permission only, not Administrator.
- The workflow makes no authenticated calls to `juspay/hyperswitch` — it only
  reads a public raw file, minimizing the credential surface entirely.
