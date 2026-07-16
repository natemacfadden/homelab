// Pure helpers for the review scheduler: parse manifest.csv, health-check it
// against the repos on disk, and weigh repos by importance x staleness.

// CSV parsing
// ===========

// Minimal RFC4180 parser: quoted fields, embedded commas/newlines, "" escapes.
// Returns an array of string-cell rows.
export function parseCsv(text) {
  const rows = []
  let row = []
  let field = ''
  let quoted = false
  const s = String(text || '')
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (quoted) {
      if (c === '"' && s[i + 1] === '"') { field += '"'; i++ }
      else if (c === '"') quoted = false
      else field += c
    } else if (c === '"') {
      quoted = true
    } else if (c === ',') {
      row.push(field); field = ''
    } else if (c === '\n') {
      row.push(field); rows.push(row); row = []; field = ''
    } else if (c !== '\r') {
      field += c
    }
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row) }
  return rows
}

// Serialize rows back to CSV (RFC4180 quoting) - inverse of parseCsv.
export function toCsv(rows) {
  const cell = (v) => {
    const s = String(v == null ? '' : v)
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  return rows.map(r => r.map(cell).join(',')).join('\n') + '\n'
}

// Manifest model
// ==============

const NA = new Set(['', 'n/a', 'na', 'none'])
const cell = (v) => {
  const t = String(v == null ? '' : v).trim()
  return NA.has(t.toLowerCase()) ? null : t
}
const bool = (v) => (v === '1' ? true : v === '0' ? false : null)

const HEADERS = {
  'repo': 'repo',
  'to review': 'toReview',
  'mine?': 'mine',
  '0-10 importance': 'importance',
  'profile': 'profile',
  'specialization': 'specialization',
  'flavor': 'flavor',
  'note': 'note',
  'last reviewed': 'lastReviewedCsv',
  'memory heavy': 'memoryHeavy',
}

// Normalize parsed rows into manifest entries (n/a -> null).
export function toManifest(rows) {
  if (!rows.length) return []
  const keys = rows[0].map(h => HEADERS[h.trim().toLowerCase()] || h.trim())
  return rows.slice(1)
    .filter(r => r.some(c => String(c).trim() !== ''))
    .map(r => {
      const o = {}
      keys.forEach((k, i) => { o[k] = r[i] == null ? '' : r[i] })
      const imp = cell(o.importance)
      return {
        repo: cell(o.repo),
        toReview: bool(String(o.toReview).trim()),
        mine: bool(String(o.mine).trim()),
        importance: imp == null || Number.isNaN(Number(imp)) ? null : Number(imp),
        profile: cell(o.profile),
        specialization: cell(o.specialization),
        flavor: cell(o.flavor),
        note: String(o.note || '').trim(),
        memoryHeavy: cell(o.memoryHeavy),
      }
    })
    .filter(e => e.repo)
}

// Health check
// ============

// Compare entries to disk. `fsInfo(repo)` -> { exists, git }; `onDisk` is the
// list of repo dir names present. Returns problems + the reviewable subset.
export function healthCheck(entries, fsInfo, onDisk = []) {
  const problems = []
  const reviewable = []
  const listed = new Set(entries.map(e => e.repo))
  for (const e of entries) {
    const { exists, git } = fsInfo(e.repo)
    if (!exists) {
      const expected = e.note && /not cloned|not local/i.test(e.note)
      problems.push({ repo: e.repo, level: 'skip',
        msg: expected ? 'not on disk (expected per note)' : 'not on disk' })
      continue
    }
    if (e.toReview === false) {
      problems.push({ repo: e.repo, level: 'skip', msg: 'opted out (to review = 0)' })
      continue
    }
    if (!git) problems.push({ repo: e.repo, level: 'warn', msg: 'not a git repo' })
    if (e.importance == null || e.importance <= 0) {
      problems.push({ repo: e.repo, level: 'skip', msg: 'no importance - skipped' })
      continue
    }
    if (git) reviewable.push(e)
  }
  for (const d of onDisk) {
    if (!listed.has(d) && fsInfo(d).git) {
      problems.push({ repo: d, level: 'warn', msg: 'git repo on disk, not in manifest' })
    }
  }
  return { problems, reviewable }
}

// Selection
// =========

// Fractional days since a timestamp - minute resolution, not floored - so a
// just-reviewed repo differs from one reviewed earlier the same day.
export function daysSince(ms, nowMs) {
  return ms == null ? null : Math.max(0, (nowMs - ms) / 86400000)
}

// importance x staleness. Never-reviewed uses neverDays; the +1 keeps a
// just-reviewed repo from dropping to zero.
export function weightFor(importance, days, neverDays = 60) {
  const imp = importance || 0
  if (imp <= 0) return 0
  return imp * ((days == null ? neverDays : days) + 1)
}

// Deterministic PRNG so a run is reproducible with --seed.
export function mulberry32(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

// Weighted pick over a weights array; returns an index, or -1 if all zero.
export function pickWeighted(weights, rng = Math.random) {
  const total = weights.reduce((a, b) => a + b, 0)
  if (total <= 0) return -1
  let r = rng() * total
  for (let i = 0; i < weights.length; i++) {
    r -= weights[i]
    if (r < 0) return i
  }
  return weights.length - 1
}
