#!/usr/bin/env node
// Review scheduler. Reads ~/github/manifest.csv, health-checks it against the
// repos on disk, picks one by importance x staleness (semi-random, weighted),
// and runs repo-review on it through the opencode adapter. Reviews are archived
// at <archive>/<repo>/<date>/.
//
//   node schedule.mjs [--dry-run] [--health] [--repo NAME] [--seed N]
//
// REPO_REVIEW_MODEL (provider/model) is passed through to the adapter.
// Paths override with REVIEW_GITHUB / REVIEW_MANIFEST / REVIEW_ARCHIVE /
// REVIEW_ADAPTER.
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { freemem } from 'node:os'
import {
  parseCsv, toCsv, toManifest, healthCheck, daysSince, weightFor, pickWeighted,
  mulberry32,
} from './manifest.mjs'

const HOME = process.env.HOME
const GITHUB = process.env.REVIEW_GITHUB || `${HOME}/github`
const MANIFEST = process.env.REVIEW_MANIFEST || `${GITHUB}/manifest.csv`
const ARCHIVE = process.env.REVIEW_ARCHIVE || `${GITHUB}/repo-review-out`
const ADAPTER = process.env.REVIEW_ADAPTER
  || `${GITHUB}/repo-review/adapters/opencode/run.mjs`
const MODEL = process.env.REPO_REVIEW_MODEL || 'ds4/deepseek-v4-flash'
const MIN_FREE_MB = Number(process.env.REVIEW_MIN_FREE_MB || 16000)
const MIN_RUN_MB = Number(process.env.REVIEW_MIN_RUN_MB || 3000)
const SKIP_HEAVY = process.env.REVIEW_SKIP_MEM_HEAVY === '1'

const argv = process.argv.slice(2)
const has = (f) => argv.includes(f)
const valOf = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : null }
const dryRun = has('--dry-run')
const healthOnly = has('--health')
const onlyRepo = valOf('--repo')
const seed = valOf('--seed')
const emitFile = valOf('--emit') // write the choice as JSON, don't run
const rng = seed != null ? mulberry32(Number(seed)) : Math.random

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

// Available RAM in MB. Prefers Linux MemAvailable; falls back to os.freemem()
// on macOS and elsewhere (coarser, but keeps the memory gate working).
function availMemMb() {
  try {
    const m = readFileSync('/proc/meminfo', 'utf8').match(/MemAvailable:\s+(\d+)\s+kB/)
    if (m) return Math.round(Number(m[1]) / 1024)
  } catch { /* not Linux - fall through */ }
  return Math.round(freemem() / 1048576)
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

// Write a generated copy of the manifest with `last reviewed` filled from the
// archive. Never touches manifest.csv itself - that stays the source of truth.
function writeReviewedManifest(cells) {
  if (cells.length < 2) return
  const header = cells[0].map(h => h.trim().toLowerCase())
  const repoIdx = header.indexOf('repo')
  const lrIdx = header.indexOf('last reviewed')
  if (repoIdx < 0 || lrIdx < 0) return
  const out = cells.map((row, i) => {
    if (i === 0) return row
    const ms = lastReviewedMs(String(row[repoIdx] || '').trim())
    if (ms == null) return row
    const copy = row.slice()
    copy[lrIdx] = new Date(ms).toISOString().slice(0, 10)
    return copy
  })
  const dest = MANIFEST.replace(/\.csv$/, '.reviewed.csv')
  writeFileSync(dest, toCsv(out))
  console.log(`reviewed copy -> ${dest} (manifest.csv untouched)`)
}

// Load + health-check.
const cells = parseCsv(readFileSync(MANIFEST, 'utf8'))
const entries = toManifest(cells)
const onDisk = listDirs(GITHUB).filter(d => d !== 'repo-review-out')
const { problems, reviewable } = healthCheck(entries, fsInfo, onDisk)

console.log(`manifest: ${entries.length} rows, ${reviewable.length} reviewable`)
for (const p of problems) console.log(`  [${p.level}] ${p.repo}: ${p.msg}`)
const avail = availMemMb()
if (avail != null) console.log(`memory: ${avail} MB available`)

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

writeReviewedManifest(cells)

if (healthOnly) process.exit(problems.some(p => p.level === 'warn') ? 1 : 0)

// Candidates: --repo overrides; otherwise every reviewable repo, weighted so
// older and never-reviewed repos dominate the draw.
let cands = rows
if (onlyRepo) {
  cands = rows.filter(r => r.e.repo === onlyRepo)
  if (!cands.length) {
    console.error(`\n--repo ${onlyRepo} is not reviewable`)
    process.exit(1)
  }
}
if (!cands.length) {
  console.log('\nno reviewable repos - nothing to do')
  process.exit(0)
}

// Memory gate (auto mode only). Skipped for --repo (explicit) and --emit
// (execution is remote, so the executor - not this box - judges memory).
if (!onlyRepo && !emitFile) {
  if (avail != null && avail < MIN_RUN_MB) {
    console.log(`\nmemory below ${MIN_RUN_MB} MB - skipping tonight`)
    process.exit(0)
  }
  if (SKIP_HEAVY || (avail != null && avail < MIN_FREE_MB)) {
    const before = cands.length
    cands = cands.filter(r => r.e.memoryHeavy !== '1')
    if (cands.length < before) {
      console.log(`\nexcluding mem-heavy repos (need ${MIN_FREE_MB} MB free)`)
    }
    if (!cands.length) {
      console.log('only mem-heavy repos are due and memory is low - skipping tonight')
      process.exit(0)
    }
  }
}

const chosen = cands[pickWeighted(cands.map(r => r.weight), rng)].e

if (emitFile) {
  const stamp = new Date().toISOString().slice(0, 19).replace(/:/g, '') + 'Z'
  writeFileSync(emitFile, JSON.stringify({
    name: chosen.repo,
    flavor: chosen.flavor,
    profile: chosen.profile,
    specialization: chosen.specialization,
    memoryHeavy: chosen.memoryHeavy === '1',
    stamp,
  }, null, 2))
  console.log(`choice -> ${emitFile}: ${chosen.repo}`)
  process.exit(0)
}

console.log(`\nchosen: ${chosen.repo}  (flavor ${chosen.flavor || 'auto'}, ` +
  `profile ${chosen.profile || 'general'})`)
if (chosen.note) console.log(`note: ${chosen.note}`)
if (chosen.memoryHeavy === '1') {
  console.log('caution: memory-heavy - do not run other heavy jobs alongside it.')
}
console.log(`model: ${MODEL}`)

// Build the adapter command; output keyed by repo + timestamp (date plus time,
// so reviewing the same repo back to back never clobbers an earlier run).
const stamp = new Date().toISOString().slice(0, 19).replace(/:/g, '') + 'Z'
const target = chosen.flavor ? `${dirOf(chosen.repo)}:${chosen.flavor}` : dirOf(chosen.repo)
const args = [ADAPTER, target]
if (chosen.profile) args.push('--profile', chosen.profile)
if (chosen.specialization) args.push('--for', chosen.specialization)
args.push('--out', ARCHIVE, '--stamp', stamp)

const shown = args.map(a => (/\s/.test(a) ? JSON.stringify(a) : a)).join(' ')
console.log(`\ncommand:\n  REPO_REVIEW_MODEL=${MODEL} node ${shown}`)
console.log(`output -> ${ARCHIVE}/${chosen.repo}/${stamp}/`)

if (dryRun) {
  console.log('\n--dry-run: not executing')
  process.exit(0)
}
const res = spawnSync('node', args,
  { stdio: 'inherit', env: { ...process.env, REPO_REVIEW_MODEL: MODEL } })
process.exit(res.status == null ? 1 : res.status)
