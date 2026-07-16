import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  parseCsv, toCsv, toManifest, healthCheck, daysSince, weightFor, pickWeighted,
  mulberry32,
} from './manifest.mjs'

// Fully synthetic fixture - exercises the parser/model only; no real data.
const CSV = [
  'repo,mine?,0-10 importance,profile,specialization,flavor,note,last reviewed,memory heavy',
  'alpha,1,6,job,role,performance,"fast, small, tested",n/a,1',
  'multi,1,4,job,x,research,"line one',
  'line two",n/a,0',
  'gamma,n/a,20,n/a,n/a,n/a,off-box,n/a,n/a',
].join('\n')

test('parseCsv: quoted commas and embedded newlines survive', () => {
  const rows = parseCsv(CSV)
  assert.equal(rows.length, 4) // header + 3 (the multi row spans two lines)
  assert.match(rows.find(r => r[0] === 'multi')[6], /line one\nline two/)
  assert.equal(rows.find(r => r[0] === 'alpha')[6], 'fast, small, tested')
})

test('toCsv: round-trips parseCsv (commas, quotes, newlines)', () => {
  const rows = [
    ['repo', 'note'],
    ['a', 'plain'],
    ['b', 'has, comma'],
    ['c', 'has "quote"'],
    ['d', 'line1\nline2'],
  ]
  assert.deepEqual(parseCsv(toCsv(rows)), rows)
})

test('healthCheck: opted-out (to review = 0) is skipped, not reviewable', () => {
  const csv = 'repo,to review,0-10 importance\nkeep,1,5\nskip,0,9'
  const m = toManifest(parseCsv(csv))
  const { problems, reviewable } =
    healthCheck(m, () => ({ exists: true, git: true }), [])
  assert.deepEqual(reviewable.map(e => e.repo), ['keep'])
  assert.ok(problems.find(p => p.repo === 'skip' && /opted out/.test(p.msg)))
})

test('toManifest: n/a -> null, importance numeric, mine boolean', () => {
  const m = toManifest(parseCsv(CSV))
  const alpha = m.find(e => e.repo === 'alpha')
  assert.equal(alpha.importance, 6)
  assert.equal(alpha.mine, true)
  assert.equal(alpha.flavor, 'performance')
  const gamma = m.find(e => e.repo === 'gamma')
  assert.equal(gamma.importance, 20)
  assert.equal(gamma.flavor, null)
  assert.equal(gamma.profile, null)
})

test('healthCheck: skip missing/no-importance, flag unlisted dirs', () => {
  const m = toManifest(parseCsv(CSV))
  const fsInfo = (r) => ({ exists: r !== 'gamma', git: r !== 'gamma' })
  const { problems, reviewable } =
    healthCheck(m, fsInfo, ['alpha', 'multi', 'stray'])
  assert.deepEqual(reviewable.map(e => e.repo).sort(), ['alpha', 'multi'])
  assert.ok(problems.find(p => p.repo === 'gamma' && p.level === 'skip'))
  assert.ok(problems.find(p => p.repo === 'stray' && /not in manifest/.test(p.msg)))
})

test('weightFor: importance x staleness; never uses neverDays', () => {
  assert.equal(weightFor(10, 0), 10)
  assert.equal(weightFor(10, 5), 60)
  assert.equal(weightFor(2, null, 60), 122)
  assert.equal(weightFor(0, null), 0)
})

test('daysSince: fractional (minute resolution), null passthrough', () => {
  const now = Date.parse('2026-07-16T00:00:00Z')
  assert.equal(daysSince(Date.parse('2026-07-10T00:00:00Z'), now), 6)
  assert.equal(daysSince(Date.parse('2026-07-15T12:00:00Z'), now), 0.5)
  assert.ok(Math.abs(daysSince(now - 60000, now) - 1 / 1440) < 1e-9) // 1 min
  assert.equal(daysSince(null, now), null)
})

test('pickWeighted: seeded rng is deterministic and respects weights', () => {
  const counts = [0, 0, 0]
  const rng = mulberry32(42)
  for (let i = 0; i < 100; i++) counts[pickWeighted([1, 0, 99], rng)]++
  assert.equal(counts[1], 0) // zero weight never chosen
  assert.ok(counts[2] > counts[0]) // heavy weight dominates
  assert.equal(pickWeighted([0, 0, 0]), -1)
})
