#!/usr/bin/env node
// Which repo to review next. Reads ~/github/manifest.csv, health-checks it
// against the repos on disk, prints the plan (importance x staleness), and -
// with --emit - draws one repo and writes the choice as JSON for driver.py.
// Selection only: it never runs a review. `./review` is the entry point.
//
//   node schedule.mjs                     print the plan; exit 1 on a warning
//   node schedule.mjs --emit F [--repo N] draw a repo, write the choice to F
//
// Paths override with REVIEW_GITHUB / REVIEW_MANIFEST / REVIEW_ARCHIVE.
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import {
  parseCsv, toManifest, healthCheck, daysSince, weightFor, pickWeighted,
} from './manifest.mjs'

const HOME = process.env.HOME
const GITHUB = process.env.REVIEW_GITHUB || `${HOME}/github`
const MANIFEST = process.env.REVIEW_MANIFEST || `${GITHUB}/manifest.csv`
const ARCHIVE = process.env.REVIEW_ARCHIVE || `${GITHUB}/repo-review-out`

const argv = process.argv.slice(2)
const valOf = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : null }
const onlyRepo = valOf('--repo')
const emitFile = valOf('--emit') // write the choice as JSON; absent = plan only

const dirOf = (repo) => `${GITHUB}/${repo}`
const fsInfo = (repo) => ({
  exists: existsSync(dirOf(repo)), git: existsSync(`${dirOf(repo)}/.git`),
})
function listDirs(base) {
  try {
    return readdirSync(base).filter(n => {
      try { return statSync(`${base}/${n}`).isDirectory() } catch { return false }
    })
  } catch { return [] }
}

// Newest archived review date (ms) for a repo, from the stamped subdirs.
function lastReviewedMs(repo) {
  let best = null
  for (const name of listDirs(`${ARCHIVE}/${repo}`)) {
    const ms = parseStamp(name)
    if (ms != null && (best == null || ms > best)) best = ms
  }
  return best
}
function parseStamp(name) {
  let m = name.match(/^(\d{4}-\d{2}-\d{2})/)
  if (m) return Date.parse(`${m[1]}T00:00:00Z`)
  m = name.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})/)
  if (m) return Date.parse(`${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z`)
  const d = Date.parse(name)
  return Number.isNaN(d) ? null : d
}

// Fractional days -> a short human age (m / h / d).
function humanAge(days) {
  if (days == null) return 'never'
  const min = days * 1440
  if (min < 60) return `${Math.round(min)}m`
  if (min < 1440) return `${Math.round(min / 60)}h`
  return `${Math.round(days)}d`
}

// Load + health-check.
const entries = toManifest(parseCsv(readFileSync(MANIFEST, 'utf8')))
const onDisk = listDirs(GITHUB).filter(d => d !== 'repo-review-out')
const { problems, reviewable } = healthCheck(entries, fsInfo, onDisk)

console.log(`manifest: ${entries.length} rows, ${reviewable.length} reviewable`)
for (const p of problems) console.log(`  [${p.level}] ${p.repo}: ${p.msg}`)

const now = Date.now()
const rows = reviewable.map(e => {
  const days = daysSince(lastReviewedMs(e.repo), now)
  return { e, days, weight: weightFor(e.importance, days) }
})

console.log('\nplan (importance x staleness):')
for (const r of [...rows].sort((a, b) => b.weight - a.weight)) {
  const mem = r.e.memoryHeavy === '1' ? '  [mem-heavy]' : ''
  console.log(`  ${r.e.repo.padEnd(15)} imp ${String(r.e.importance).padStart(2)}` +
    `   last ${humanAge(r.days).padStart(5)}` +
    `   weight ${String(Math.round(r.weight)).padStart(4)}${mem}`)
}

// Plan only: report, and fail on a warning so cron/CI notices a stale manifest.
if (!emitFile) process.exit(problems.some(p => p.level === 'warn') ? 1 : 0)

// Draw one repo: --repo forces it, otherwise weighted so older and
// never-reviewed repos dominate.
let cands = rows
if (onlyRepo) {
  cands = rows.filter(r => r.e.repo === onlyRepo)
  if (!cands.length) {
    console.error(`\n${onlyRepo} is not reviewable (see the plan above)`)
    process.exit(1)
  }
}
if (!cands.length) {
  console.log('\nno reviewable repos - nothing to do')
  process.exit(0)
}

const chosen = cands[pickWeighted(cands.map(r => r.weight))].e
if (chosen.note) console.log(`\nnote: ${chosen.note}`)

// Stamp is date + time, so reviewing the same repo twice never clobbers a run.
const stamp = new Date().toISOString().slice(0, 19).replace(/:/g, '') + 'Z'
writeFileSync(emitFile, JSON.stringify({
  name: chosen.repo,
  flavor: chosen.flavor,
  profile: chosen.profile,
  specialization: chosen.specialization,
  memoryHeavy: chosen.memoryHeavy === '1',
  stamp,
}, null, 2))
console.log(`chosen: ${chosen.repo}  (flavor ${chosen.flavor || 'auto'}, ` +
  `profile ${chosen.profile || 'general'}) -> ${ARCHIVE}/${chosen.repo}/${stamp}/`)
