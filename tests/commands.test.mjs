// The shared vectors (also run against the macOS app's Swift parsers by tests/run-swift-tests.mjs).
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { parseAppPlan, parsePermissionAnswer, parsePermissionCommand, parseTaskCommand, stripWake } from '../core/commands.mjs'

const V = JSON.parse(readFileSync(new URL('./vectors/commands.json', import.meta.url), 'utf8'))

test('task commands', () => {
  for (const [text, want] of V.taskCommands) assert.deepEqual(parseTaskCommand(text), want, text)
})

test('several apps at once', () => {
  const installed = new Set(V.installedApps)
  for (const [text, verb, stages] of V.appPlans) {
    const plan = parseAppPlan(text, (n) => installed.has(n))
    if (verb === null) assert.equal(plan, null, text)
    else assert.deepEqual(plan, { verb, stages }, text)
  }
})

test('voice commands about permissions', () => {
  const resolve = (n) => (V.permissionApps[n] ? { name: V.permissionApps[n][0], bundleID: V.permissionApps[n][1] } : null)
  const show = (c) => (!c ? 'none' : c.type === 'change' ? `${c.allow ? 'allow' : 'deny'} ${c.capability}${c.target ? ` ${c.target}` : ''}` : c.type === 'can' ? `can ${c.what}` : c.type)
  for (const [text, want] of V.permissionCommands) assert.equal(show(parsePermissionCommand(text, resolve)), want, text)
})

test('answers to permission questions: only clear, whole answers count', () => {
  for (const [text, want] of V.permissionAnswers) assert.equal(parsePermissionAnswer(text), want, text)
})

test('the wake phrase, including the recogniser\'s usual spellings of it', () => {
  assert.deepEqual(stripWake('Hey Jarvis, open the calculator.'), { woke: true, request: 'open the calculator.' })
  assert.deepEqual(stripWake('Hey, Javis.'), { woke: true, request: '' })
  assert.deepEqual(stripWake('Hey, Javes.'), { woke: true, request: '' })
  assert.deepEqual(stripWake('Jarvis what time is it'), { woke: true, request: 'what time is it' })
  assert.equal(stripWake('Hey, the service is down again.').woke, false)
  assert.equal(stripWake('Hand me those jars, please.').woke, false)
  assert.equal(stripWake('Javis is my friend').woke, false, 'fuzzy spellings only count after "hey"')
})
