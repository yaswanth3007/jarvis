/**
 * The task orchestrator for the Windows and Linux voice assistant — the same rules as
 * Jarvis Voice's on macOS (macos/JarvisVoice/Tasks.swift), so "open Firefox and VS Code",
 * "what are you doing?" and "stop task 2" behave the same everywhere.
 *
 *   - Independent tasks run at the same time; a task waits only for what it needs.
 *   - Resources: `exclusive` ones (an app being typed into, the keyboard, the camera)
 *     are held by one task at a time; `shared` ones (focus while opening apps) by any
 *     number of tasks, but never while another task holds them exclusively.
 *   - Dependencies: a task can wait for others; with requireSuccess it is skipped
 *     when one of them did not succeed.
 *   - Per-kind limits (lowered while the computer is short of memory), timeouts,
 *     retries for transient failures, and cancellation that only touches the task
 *     asked for — a waiting task that is cancelled never starts.
 */
import { freemem, totalmem, loadavg, cpus } from 'node:os'
import { normalized } from './commands.mjs'

export const Status = Object.freeze({ queued: 'queued', waiting: 'waiting', running: 'running', done: 'done', failed: 'failed', cancelled: 'cancelled' })
const FINISHED = new Set([Status.done, Status.failed, Status.cancelled])

/** Outcomes a task's work returns. */
export const done = (message = '') => ({ ok: true, message })
export const failed = (message = '', { retry = false } = {}) => ({ ok: false, message, retry })

/** Short of memory or CPU right now? (Windows has no load average; memory still counts.) */
export function systemBusy() {
  const free = freemem() / totalmem()
  if (free < 0.05) return { busy: true, why: 'memory is low' }
  const load = loadavg()[0]
  if (load > 0 && load > cpus().length * 1.5) return { busy: true, why: 'the processor is busy' }
  return { busy: false, why: '' }
}

let nextId = 1

export class Job {
  constructor(title, o) {
    this.id = nextId++
    this.title = title
    this.kind = o.kind
    this.exclusive = new Set(o.exclusive ?? [])
    this.shared = new Set(o.shared ?? [])
    this.dependsOn = [...(o.dependsOn ?? [])]
    this.requireSuccess = Boolean(o.requireSuccess)
    this.cancellable = o.cancellable !== false
    this.parent = o.parent ?? null
    this.timeout = o.timeout ?? null
    this.retries = o.retries ?? 0
    this.logTitle = o.sensitiveTitle ?? title
    this.status = Status.queued
    this.detail = ''
    this.message = ''
    this.created = new Date()
    this.started = null
    this.finished = null
    this.attempts = 0
    this.acquired = false
    this.onCancel = null
    this.controller = new AbortController()
    this._waiters = []
  }
  get signal() {
    return this.controller.signal
  }
  get isActive() {
    return !FINISHED.has(this.status)
  }
  get elapsedMs() {
    return this.started ? ((this.finished ?? new Date()) - this.started) : 0
  }
  get waitedMs() {
    return ((this.started ?? this.finished ?? new Date()) - this.created)
  }
}

export class TaskManager {
  constructor({ log = () => {} } = {}) {
    this.jobs = []
    this.limits = { app: 6, mac: 4, desktop: 4, claude: 3, camera: 1 }
    this.maxQueued = 4
    this.log = log
    this.onChange = null
  }

  get active() {
    return this.jobs.filter((j) => j.isActive)
  }
  get latestActive() {
    return [...this.active].sort((a, b) => b.id - a.id).find((j) => j.parent === null) ?? null
  }
  job(id) {
    return this.jobs.find((j) => j.id === id) ?? null
  }
  running(kind) {
    return this.jobs.filter((j) => j.kind === kind && j.status === Status.running).length
  }
  limit(kind) {
    const base = this.limits[kind] ?? 4
    if (!systemBusy().busy) return base
    if (kind === 'claude') return Math.max(1, base - 1)
    if (kind === 'app' || kind === 'mac' || kind === 'desktop') return Math.max(2, Math.floor(base / 2))
    return base
  }
  waitingCount(kind) {
    return this.jobs.filter((j) => j.kind === kind && (j.status === Status.queued || j.status === Status.waiting) && !j.acquired).length
  }
  /** Whether a new task of this kind would have to wait for a free slot. */
  wouldQueue(kind) {
    return this.running(kind) + this.waitingCount(kind) >= this.limit(kind)
  }

  /**
   * @param {string} title
   * @param {{kind: string, exclusive?: string[], shared?: string[], dependsOn?: number[], requireSuccess?: boolean,
   *          timeout?: number, retries?: number, cancellable?: boolean, parent?: number, sensitiveTitle?: string}} o
   * @param {(job: Job) => Promise<{ok: boolean, message: string, retry?: boolean}>} work
   */
  run(title, o, work) {
    const job = new Job(title, o)
    job.work = work
    this.jobs.push(job)
    this.prune()
    this.log(`task ${job.id} queued: ${job.logTitle} (${job.kind})`)
    this.pump()
    return job
  }

  /** Cancels one task (and its subtasks). Returns false if it had already finished. */
  cancel(jobOrId, reason = 'cancelled') {
    const job = typeof jobOrId === 'number' ? this.job(jobOrId) : jobOrId
    if (!job || !job.isActive || !job.cancellable) return false
    for (const child of this.jobs.filter((j) => j.parent === job.id && j.isActive)) this.cancel(child, reason)
    const wasRunning = job.status === Status.running
    job.controller.abort(reason)
    if (wasRunning) {
      try {
        job.onCancel?.()
      } catch {
        /* cleanup is best effort */
      }
    }
    this.finish(job, Status.cancelled, reason)
    return true
  }

  /** Newest first, ignoring filler words: "the Chrome task", "opening spotify". */
  find(phrase) {
    const ignored = new Set(['the', 'a', 'an', 'my', 'your', 'task', 'job', 'one', 'that', 'this', 'for', 'of', 'to'])
    const words = normalized(phrase).split(' ').filter((w) => w && !ignored.has(w))
    if (!words.length) return null
    const candidates = [...this.active.filter((j) => j.parent === null), ...this.active.filter((j) => j.parent !== null)]
    return candidates.sort((a, b) => b.id - a.id).find((j) => {
      const title = normalized(j.title)
      return words.every((w) => title.includes(w))
    }) ?? null
  }

  wait(job) {
    if (!job.isActive) return Promise.resolve(job)
    return new Promise((resolve) => job._waiters.push(resolve))
  }
  waitAll(jobs) {
    return Promise.all(jobs.map((j) => this.wait(j)))
  }

  // -- internals -------------------------------------------------------------

  prune() {
    if (this.jobs.length <= 60) return
    const finished = this.jobs.filter((j) => !j.isActive)
    const drop = new Set(finished.slice(0, this.jobs.length - 60))
    this.jobs = this.jobs.filter((j) => !drop.has(j))
  }

  conflicts(job) {
    for (const other of this.jobs) {
      if (other === job || other.status !== Status.running) continue
      for (const r of job.exclusive) if (other.exclusive.has(r) || other.shared.has(r)) return other
      for (const r of job.shared) if (other.exclusive.has(r)) return other
    }
    return null
  }

  pump() {
    for (const job of this.jobs) {
      if (job.status !== Status.queued && job.status !== Status.waiting) continue
      // Dependencies first.
      let blocked = false
      for (const depId of job.dependsOn) {
        const dep = this.job(depId)
        if (!dep) continue
        if (dep.isActive) {
          job.status = Status.waiting
          job.detail = `waiting for task ${dep.id}`
          blocked = true
          break
        }
        if (job.requireSuccess && dep.status !== Status.done) {
          this.finish(job, Status.cancelled, `skipped: “${dep.title}” did not succeed`)
          blocked = true
          break
        }
      }
      if (blocked || !job.isActive) continue
      if (this.running(job.kind) >= this.limit(job.kind)) {
        job.status = Status.waiting
        job.detail = 'waiting for a free slot'
        continue
      }
      const holder = this.conflicts(job)
      if (holder) {
        job.status = Status.waiting
        job.detail = `waiting for task ${holder.id}`
        continue
      }
      this.start(job)
    }
    this.onChange?.()
  }

  start(job) {
    job.status = Status.running
    job.acquired = true
    job.detail = ''
    job.started = new Date()
    this.log(`task ${job.id} running: ${job.logTitle}`)
    void this.attempt(job)
  }

  async attempt(job) {
    while (job.isActive) {
      job.attempts++
      let outcome
      let timer = null
      try {
        const work = Promise.resolve().then(() => job.work(job))
        outcome = job.timeout
          ? await Promise.race([work, new Promise((r) => { timer = setTimeout(() => r({ timedOut: true }), job.timeout * 1000) })])
          : await work
      } catch (err) {
        outcome = failed(String(err?.message ?? err))
      } finally {
        if (timer) clearTimeout(timer)
      }
      if (!job.isActive) return // cancelled while it ran: its result no longer matters
      if (outcome?.timedOut) {
        job.controller.abort('timed out')
        try {
          job.onCancel?.()
        } catch {
          /* best effort */
        }
        this.finish(job, Status.failed, `timed out after ${job.timeout} seconds`)
        return
      }
      if (outcome?.ok) {
        this.finish(job, Status.done, outcome.message ?? '')
        return
      }
      if (outcome?.retry && job.attempts <= job.retries) {
        job.detail = 'trying again'
        continue
      }
      this.finish(job, Status.failed, outcome?.message ?? 'failed')
      return
    }
  }

  finish(job, status, message) {
    if (!job.isActive) return
    job.status = status
    job.message = message ?? ''
    job.detail = ''
    job.finished = new Date()
    this.log(`task ${job.id} ${status}: ${job.logTitle}${message && status !== Status.done ? ` — ${message}` : ''}`)
    const waiters = job._waiters.splice(0)
    for (const w of waiters) w(job)
    // Freed resources may let others start.
    queueMicrotask(() => this.pump())
  }
}
