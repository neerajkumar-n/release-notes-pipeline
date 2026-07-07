import {createClient} from '@sanity/client'
import {readFileSync} from 'node:fs'

const token = process.env.SANITY_WRITE_TOKEN
if (!token) {
  console.error('Missing SANITY_WRITE_TOKEN')
  process.exit(1)
}

const client = createClient({
  projectId: process.env.SANITY_PROJECT_ID || '5ybiq59b',
  dataset: process.env.SANITY_DATASET || 'production',
  apiVersion: '2024-01-01',
  token,
  useCdn: false,
})

const KNOWN = new Set(['weekStart', 'weekEnd', 'prCount', 'generatedAt', 'highlights'])

function toSanityDoc(p) {
  if (!p?.weekStart) throw new Error('payload.weekStart is required (used for _id)')
  const sections = Object.keys(p)
    .filter((k) => !KNOWN.has(k) && Array.isArray(p[k]))
    .map((k, si) => ({
      _key: `sec-${si}`, _type: 'section', key: k,
      items: p[k].map((it, i) => ({
        _key: `item-${si}-${i}`, _type: 'item',
        title: it.title || '',
        prNumbers: Array.isArray(it.prNumbers) ? it.prNumbers : [],
        prLinks: Array.isArray(it.prLinks) ? it.prLinks : [],
      })),
    }))
  return {
    _id: `weekly-pr-summary-${p.weekStart}`,
    _type: 'weekly_pr_summary',
    weekStart: p.weekStart, weekEnd: p.weekEnd, prCount: p.prCount,
    generatedAt: p.generatedAt,
    highlights: (p.highlights || []).map((h, i) => ({
      _key: `hl-${i}`, _type: 'highlight',
      theme: h.theme || '', description: h.description || '',
    })),
    sections,
    rawPayload: JSON.stringify(p),
  }
}

const file = process.argv[2] || 'summary.json'
const payload = JSON.parse(readFileSync(file, 'utf8'))
const doc = toSanityDoc(payload)

const res = await client.createOrReplace(doc)
console.log(`Wrote ${res._id} — ${doc.sections.length} sections, ` +
  `${doc.sections.reduce((n, s) => n + s.items.length, 0)} items`)
