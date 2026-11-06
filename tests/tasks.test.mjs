// The same orchestrator behaviour the macOS app's Swift tests check (macos/Tests/main.swift).
import test from 'node:test'
import assert from 'node:assert/strict'
import { done, failed, TaskManager } from '../core/tasks.mjs'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

test('independent tasks overlap: the total is close to the longest, not the sum', async () => {
  const m = new TaskManager()
  const t0 = Date.now()
  const jobs = [0, 1, 2].map((i) => m.run(`job ${i}`, { kind: 'app', exclusive: [`app:${i}`], shared: ['focus'] }, async () => { await sleep(300); return done('ok') }))
  await m.waitAll(jobs)
  assert.ok(Date.now() - t0 < 550, `${Date.now() - t0} ms`)
})

test('tasks sharing an exclusive resource never overlap', async () => {
  const m = new TaskManager()
  const jobs = [0, 1, 2].map((i) => m.run(`type ${i}`, { kind: 'desktop', exclusive: ['app:x', 'keyboard'] }, async () => { await sleep(150); return done('ok') }))
  await m.waitAll(jobs)
  for (let i = 1; i < jobs.length; i++) assert.ok(jobs[i - 1].finished <= jobs[i].started)
})

test('opening an app waits while another task is typing; two opens share focus', async () => {
  const m = new TaskManager()
  const typing = m.run('typing', { kind: 'desktop', exclusive: ['app:a', 'focus', 'keyboard'] }, async () => { await sleep(250); return done('ok') })
  await sleep(20)
  const o1 = m.run('open b', { kind: 'app', exclusive: ['app:b'], shared: ['focus'] }, async () => { await sleep(80); return done('ok') })
  const o2 = m.run('open c', { kind: 'app', exclusive: ['app:c'], shared: ['focus'] }, async () => { await sleep(80); return done('ok') })
  await m.waitAll([typing, o1, o2])
  assert.ok(o1.started >= typing.finished)
  assert.ok(Math.abs(o1.started - o2.started) < 50)
})

test('dependencies: after, and skipped when a required step failed; failures stay isolated', async () => {
  const m = new TaskManager()
  const a = m.run('open chrome', { kind: 'app' }, async () => { await sleep(100); return done('ok') })
  const b = m.run('search', { kind: 'desktop', dependsOn: [a.id], requireSuccess: true }, async () => done('ok'))
  await m.waitAll([a, b])
  assert.ok(b.started >= a.finished)
  const c = m.run('open missing', { kind: 'app' }, async () => failed("isn't installed"))
  const d = m.run('search in it', { kind: 'desktop', dependsOn: [c.id], requireSuccess: true }, async () => done('ok'))
  const e = m.run('unrelated', { kind: 'app' }, async () => done('ok'))
  await m.waitAll([c, d, e])
  assert.equal(d.status, 'cancelled')
  assert.equal(d.started, null)
  assert.equal(e.status, 'done')
})

test('cancelling touches only that task; its cleanup runs; a waiting task never starts', async () => {
  const m = new TaskManager()
  let cleaned = false
  const long = m.run('long', { kind: 'claude' }, async () => { await sleep(2000); return done('ok') })
  long.onCancel = () => { cleaned = true }
  const other = m.run('other', { kind: 'claude' }, async () => { await sleep(200); return done('ok') })
  const blocked = m.run('blocked', { kind: 'desktop', exclusive: ['x'] }, async () => { await sleep(1000); return done('ok') })
  const waiting = m.run('waiting', { kind: 'desktop', exclusive: ['x'] }, async () => done('ran'))
  await sleep(50)
  m.cancel(long)
  m.cancel(waiting)
  await m.wait(other)
  assert.equal(long.status, 'cancelled')
  assert.ok(cleaned)
  assert.equal(other.status, 'done')
  assert.equal(waiting.status, 'cancelled')
  assert.equal(waiting.started, null)
  m.cancel(blocked)
})

test('timeouts stop a task; a transient failure is retried once', async () => {
  const m = new TaskManager()
  let stopped = false
  const slow = m.run('slow', { kind: 'desktop', timeout: 0.2 }, async () => { await sleep(3000); return done('late') })
  slow.onCancel = () => { stopped = true }
  let attempts = 0
  const flaky = m.run('flaky', { kind: 'app', retries: 1 }, async () => (++attempts === 1 ? failed('transient', { retry: true }) : done('opened')))
  await m.waitAll([slow, flaky])
  assert.equal(slow.status, 'failed')
  assert.ok(stopped)
  assert.match(slow.message, /timed out/)
  assert.equal(flaky.status, 'done')
  assert.equal(flaky.attempts, 2)
})

test('per-kind limits: a third Claude task waits for a free slot', async () => {
  const m = new TaskManager()
  m.limits.claude = 2
  const jobs = [0, 1, 2].map((i) => m.run(`claude ${i}`, { kind: 'claude' }, async () => { await sleep(200); return done('ok') }))
  await sleep(30)
  assert.equal(jobs[2].status, 'waiting')
  assert.ok(m.wouldQueue('claude'))
  await m.waitAll(jobs)
  assert.equal(jobs[2].status, 'done')
  assert.ok(jobs[2].started >= Math.min(jobs[0].finished, jobs[1].finished))
})

test('finding tasks by name, newest first', async () => {
  const m = new TaskManager()
  const a = m.run('opening Google Chrome', { kind: 'app' }, async () => { await sleep(150); return done('ok') })
  const b = m.run('opening Spotify', { kind: 'app' }, async () => { await sleep(150); return done('ok') })
  assert.equal(m.find('chrome')?.id, a.id)
  assert.equal(m.find('opening spotify')?.id, b.id)
  assert.equal(m.latestActive?.id, b.id)
  await m.waitAll([a, b])
})

test('orchestration overhead per task (measured, reported)', async () => {
  const m = new TaskManager()
  const samples = []
  for (let i = 0; i < 200; i++) {
    const t0 = process.hrtime.bigint()
    await m.wait(m.run(`noop ${i}`, { kind: 'app' }, async () => done('')))
    samples.push(Number(process.hrtime.bigint() - t0) / 1e6)
  }
  samples.sort((x, y) => x - y)
  const median = samples[100]
  const p95 = samples[190]
  console.log(`# task overhead: median ${median.toFixed(3)} ms, p95 ${p95.toFixed(3)} ms (n=200)`)
  assert.ok(median < 20)
})
