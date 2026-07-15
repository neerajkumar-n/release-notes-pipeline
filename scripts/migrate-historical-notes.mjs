import {createClient} from '@sanity/client'
import {readFileSync} from 'node:fs'

const token = process.env.SANITY_WRITE_TOKEN
if (!token) {
  console.error('Missing SANITY_WRITE_TOKEN')
  process.exit(1)
}

const BATCH_SIZE = parseInt(process.env.BATCH_SIZE || '5', 10)
const CACHE_PATH = process.argv[2] || '../release-notes/app/data/summary-cache.json'

const client = createClient({
  projectId: process.env.SANITY_PROJECT_ID || '5ybiq59b',
  dataset: process.env.SANITY_DATASET || 'production',
  apiVersion: '2024-01-01',
  token,
  useCdn: false,
})

// ── HTML Parsing ──

function decodeEntities(s) {
  return s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
}

function stripTags(s) {
  return s.replace(/<[^>]+>/g, '')
}

function toCamelCase(text) {
  const cleaned = text.replace(/[^\w\s&]/g, '')
  const words = cleaned.split(/[\s&]+/).filter(Boolean)
  if (!words.length) return ''
  return words[0].toLowerCase() + words.slice(1).map(w => w.charAt(0).toUpperCase() + w.slice(1)).join('')
}

const SECTION_KEY_MAP = {
  'Connectors': 'connectors',
  'Customer & Access Management': 'customerAccessManagement',
  'Routing & Core Improvements': 'routingAndCore',
}

function headingToKey(heading) {
  return SECTION_KEY_MAP[heading] || toCamelCase(heading)
}

function parseHighlights(html) {
  const highlights = []
  // Find the Weekly Highlights section — from the h3 to the first content section (rounded-xl border)
  const hlStart = html.indexOf('Weekly Highlights')
  if (hlStart === -1) return highlights
  const hlEnd = html.indexOf('<div class="rounded-xl border', hlStart)
  const block = html.slice(hlStart, hlEnd > -1 ? hlEnd : html.length)

  // Each highlight is in <div class="space-y-1"> with a theme div and description p
  const itemRegex = /<div class="space-y-1">[\s\S]*?<div class="text-xs font-bold[^"]*">([^<]+)<\/div>[\s\S]*?<p class="text-sm[^"]*">([\s\S]*?)<\/p>[\s\S]*?<\/div>/g
  let m
  while ((m = itemRegex.exec(block)) !== null) {
    highlights.push({
      theme: m[1].trim(),
      description: m[2].trim(),
    })
  }
  return highlights
}

function parseSections(html) {
  const sections = {}
  // Split by section headers — <h4 ...>NAME</h4> inside a rounded-xl border container
  // Find all h4 headings and their content
  const h4Regex = /<h4[^>]*>([^<]+)<\/h4>/g
  const h4Matches = []
  let m
  while ((m = h4Regex.exec(html)) !== null) {
    h4Matches.push({
      name: decodeEntities(m[1].trim()),
      index: m.index + m[0].length,
    })
  }

  for (let i = 0; i < h4Matches.length; i++) {
    const section = h4Matches[i]
    // Content goes from after this h4 to the next h4 or end of a rounded-xl div
    const nextIndex = i + 1 < h4Matches.length ? h4Matches[i + 1].index : html.length
    // But we need to stop at the end of the current section's container div
    // Find the content between this h4 and the next section's container start
    // The items are in <div class="divide-y ...">...</div>
    const contentStart = section.index
    // Find the next "rounded-xl border" div which starts a new section, or end of html
    const nextSectionStart = html.indexOf('<div class="rounded-xl border', contentStart)
    const contentEnd = nextSectionStart > -1 && nextSectionStart < nextIndex ? nextSectionStart : nextIndex
    const sectionHtml = html.slice(contentStart, contentEnd)

    const key = headingToKey(section.name)
    if (!key) continue

    const items = parseSectionItems(sectionHtml)
    if (!sections[key]) sections[key] = []
    sections[key].push(...items)
  }

  return sections
}

function parseSectionItems(sectionHtml) {
  const items = []
  // Each item is a <div class="p-4 ..."> ... </div>
  // Split by p-4 divs
  const itemRegex = /<div class="p-4[^"]*"[^>]*>([\s\S]*?)<\/div>(?=\s*<div class="p-4|\s*<\/div>\s*<\/div>)/g
  let m
  while ((m = itemRegex.exec(sectionHtml)) !== null) {
    const itemHtml = m[1]
    const item = parseItem(itemHtml)
    if (item) items.push(item)
  }

  // Fallback: if the regex didn't match, try a simpler approach
  if (items.length === 0) {
    const simpleItems = sectionHtml.split(/<div class="p-4[^"]*"/).slice(1)
    for (const chunk of simpleItems) {
      const item = parseItem(chunk)
      if (item) items.push(item)
    }
  }

  return items
}

function parseItem(itemHtml) {
  // Extract label (optional) — <span class="shrink-0 w-32 ...">LABEL</span>
  const labelMatch = itemHtml.match(/<span class="shrink-0 w-32[^"]*">([^<]+)<\/span>/)
  const label = labelMatch ? labelMatch[1].trim() : ''

  // Extract description — <span class="text-sm text-slate-600...">DESC</span>
  const descMatch = itemHtml.match(/<span class="text-sm text-slate-600[^"]*">([\s\S]*?)<\/span>/)
  const description = descMatch ? descMatch[1].replace(/<[^>]+>/g, '').trim() : ''

  // Extract PR link — <a href="PR_URL" ...>View PR #XXXXX</a> or #XXXXX
  const prMatches = []
  const prRegex = /<a href="(https:\/\/github\.com\/juspay\/hyperswitch\/pull\/(\d+))"[^>]*>[\s\S]*?<\/a>/g
  let pm
  while ((pm = prRegex.exec(itemHtml)) !== null) {
    prMatches.push({
      url: pm[1],
      number: parseInt(pm[2], 10),
    })
  }

  if (prMatches.length === 0 && !description) return null

  const prNumbers = prMatches.map(p => p.number)
  const prLinks = prMatches.map(p => p.url)

  const title = description || label || ''

  return {
    title,
    label,
    description,
    prNumbers,
    prLinks,
  }
}

// ── Sanity doc builder ──

const KNOWN = new Set(['weekStart', 'weekEnd', 'prCount', 'generatedAt', 'highlights'])

function toSanityDoc(p) {
  const sections = Object.keys(p)
    .filter(k => !KNOWN.has(k) && Array.isArray(p[k]))
    .map((k, si) => ({
      _key: `sec-${si}`, _type: 'section', key: k,
      items: p[k].map((it, i) => ({
        _key: `item-${si}-${i}`, _type: 'item',
        title: it.title || '',
        label: it.label || '',
        description: it.description || '',
        prNumbers: Array.isArray(it.prNumbers) ? it.prNumbers : [],
        prLinks: Array.isArray(it.prLinks) ? it.prLinks : [],
      })),
    }))

  return {
    _id: `weekly-pr-summary-${p.weekStart}`,
    _type: 'weekly_pr_summary',
    weekStart: p.weekStart,
    weekEnd: p.weekEnd,
    prCount: p.prCount,
    generatedAt: p.generatedAt,
    highlights: (p.highlights || []).map((h, i) => ({
      _key: `hl-${i}`, _type: 'highlight',
      theme: h.theme || '', description: h.description || '',
    })),
    sections,
    rawPayload: JSON.stringify(p),
  }
}

// ── Week date calculation ──

function getNextWednesday(dateStr) {
  const d = new Date(dateStr + 'T00:00:00Z')
  const day = d.getUTCDay() // 0=Sun, 3=Wed
  const daysToWed = (3 - day + 7) % 7
  d.setUTCDate(d.getUTCDate() + daysToWed)
  return d.toISOString().slice(0, 10)
}

function getWeekEnd(weekStart) {
  const d = new Date(weekStart + 'T00:00:00Z')
  d.setUTCDate(d.getUTCDate() + 6)
  return d.toISOString().slice(0, 10)
}

// ── Main ──

const cache = JSON.parse(readFileSync(CACHE_PATH, 'utf8'))
const dates = Object.keys(cache).sort()
const nonEmpty = dates.filter(d => cache[d] && cache[d].trim() !== '')

console.log(`\n=== Historical Notes Migration ===`)
console.log(`Total entries: ${dates.length}, non-empty: ${nonEmpty.length}, batch size: ${BATCH_SIZE}\n`)

const payloads = []

for (const date of nonEmpty) {
  const html = cache[date]
  const highlights = parseHighlights(html)
  const sections = parseSections(html)
  const allPrs = Object.values(sections).flat().filter(i => i.prNumbers.length > 0)
  const prCount = new Set(allPrs.flatMap(i => i.prNumbers)).size

  const weekStart = getNextWednesday(date)
  const weekEnd = getWeekEnd(weekStart)

  const payload = {
    weekStart,
    weekEnd,
    prCount,
    generatedAt: new Date().toISOString(),
    highlights,
    ...sections,
  }

  payloads.push(payload)

  const sectionSummary = Object.entries(sections)
    .map(([k, v]) => `${k}(${v.length})`)
    .join(', ')

  console.log(`  ${date} → weekStart ${weekStart}: ${highlights.length} highlights, ${prCount} PRs, sections: ${sectionSummary}`)
}

console.log(`\nParsed ${payloads.length} payloads. Pushing in batches of ${BATCH_SIZE}...\n`)

let success = 0
let failed = 0

for (let i = 0; i < payloads.length; i += BATCH_SIZE) {
  const batch = payloads.slice(i, i + BATCH_SIZE)
  const batchNum = Math.floor(i / BATCH_SIZE) + 1
  const totalBatches = Math.ceil(payloads.length / BATCH_SIZE)
  console.log(`--- Batch ${batchNum}/${totalBatches} ---`)

  for (const payload of batch) {
    try {
      const doc = toSanityDoc(payload)
      const res = await client.createOrReplace(doc)
      const itemCount = doc.sections.reduce((n, s) => n + s.items.length, 0)
      console.log(`  ✓ ${res._id} — ${doc.sections.length} sections, ${itemCount} items`)
      success++
    } catch (err) {
      console.error(`  ✗ weekly-pr-summary-${payload.weekStart}: ${err.message}`)
      failed++
    }
  }

  if (i + BATCH_SIZE < payloads.length) {
    console.log('  (pausing 1s between batches...)\n')
    await new Promise(r => setTimeout(r, 1000))
  }
}

console.log(`\n=== Done: ${success} succeeded, ${failed} failed ===`)
