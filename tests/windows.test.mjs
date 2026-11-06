// Windows adapter on a real Windows desktop (CI runners have one): Start-menu apps, UI
// Automation, SendKeys, screen capture. Runs on Windows when JARVIS_E2E_DESKTOP=1.
import test from 'node:test'
import assert from 'node:assert/strict'

const desktop = process.platform === 'win32' && process.env.JARVIS_E2E_DESKTOP === '1'
const skip = desktop ? false : 'needs Windows with JARVIS_E2E_DESKTOP=1'

test('the Windows helper starts and answers', { skip }, async () => {
  const { WindowsAdapter } = await import('../client/adapters/windows.mjs')
  const a = new WindowsAdapter()
  const t0 = Date.now()
  await a.start()
  console.log(`# windows helpers started in ${Date.now() - t0} ms`)
  assert.equal(await a.ui.call('ping'), 'pong')
  const t1 = Date.now()
  for (let i = 0; i < 20; i++) await a.ui.call('ping')
  console.log(`# windows helper round trip: ${((Date.now() - t1) / 20).toFixed(1)} ms`)
  a.stop()
})

test('apps: list, open Notepad, read and type through UI Automation, keys, screenshot, close', { skip }, async () => {
  const { WindowsAdapter } = await import('../client/adapters/windows.mjs')
  const a = new WindowsAdapter({ log: (m) => console.log(`# ${m}`) })
  await a.start()
  const timings = {}
  const time = async (name, fn) => {
    const t0 = Date.now()
    const v = await fn()
    timings[name] = Date.now() - t0
    return v
  }
  try {
    const apps = await time('list', () => a.installedApps(true))
    assert.ok(apps.length > 0, 'the Start menu lists apps')
    console.log(`# before opening, a Notepad window: ${JSON.stringify(await a.find('Notepad').catch((e) => e.message))}`)
    const notepad = await a.resolveApp('Notepad')
    console.log(`# Start menu: ${apps.length} apps; Notepad is ${JSON.stringify(notepad)}`)
    const opened = await time('open', () => a.openApp('Notepad'))
    console.log(`# open: ${opened.message}`)
    assert.ok(opened.ok, opened.message)
    await new Promise((r) => setTimeout(r, 1500))
    const read = await time('read', () => a.readWindow('Notepad')).catch(async (err) => {
      console.log(`# windows now: ${JSON.stringify(await a.running())}`)
      throw err
    })
    assert.ok(read.title.length > 0, JSON.stringify(read).slice(0, 200))
    const typed = await time('type', () => a.typeText('Notepad', 'hello from jarvis'))
    assert.match(typed, /typed/)
    await new Promise((r) => setTimeout(r, 300))
    assert.match((await a.readWindow('Notepad')).text, /hello from jarvis/)
    assert.equal(await time('keys', () => a.pressKeys('Notepad', 'ctrl+a')), 'pressed')
    const front = await a.frontmost()
    assert.ok(front, 'something is in front')
    const shot = await time('screenshot', () => a.screenshot({}))
    assert.ok(shot.image.length > 1000)
    // Unsaved text: Notepad asks (or keeps the tab, on Windows 11) — either way Jarvis says so honestly.
    const closed = await time('close', () => a.closeApp('Notepad'))
    console.log(`# close with unsaved text: ${closed.message}`)
    console.log(`# windows desktop actions (ms): ${JSON.stringify(timings)}`)
  } finally {
    await a.closeApp('Notepad', { force: true }).catch(() => {})
    a.stop()
  }
})
