// Linux adapter. The parsing tests run everywhere; the desktop tests (a real X11 session with
// AT-SPI, as CI provides under Xvfb) run on Linux when JARVIS_E2E_DESKTOP=1.
import test from 'node:test'
import assert from 'node:assert/strict'
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { LinuxAdapter, parseExec, xdotoolKeys } from '../client/adapters/linux.mjs'
import { matchApp } from '../client/adapters/common.mjs'

test('desktop entry Exec lines: quoting, escapes and field codes', () => {
  assert.deepEqual(parseExec('firefox %u'), ['firefox'])
  assert.deepEqual(parseExec('"/opt/My App/bin/app" --flag %F'), ['/opt/My App/bin/app', '--flag'])
  assert.deepEqual(parseExec('sh -c "echo \\"hi\\" \\$HOME"'), ['sh', '-c', 'echo "hi" $HOME'])
  assert.deepEqual(parseExec('app --percent=100%%'), ['app', '--percent=100%'])
  assert.deepEqual(parseExec('env FOO=1 gedit %U'), ['env', 'FOO=1', 'gedit'])
})

test('key names for xdotool', () => {
  assert.equal(xdotoolKeys('ctrl+shift+p'), 'ctrl+shift+p')
  assert.equal(xdotoolKeys('enter'), 'Return')
  assert.equal(xdotoolKeys('cmd+l'), 'ctrl+l')
  assert.equal(xdotoolKeys('alt+F4'), 'alt+F4')
  assert.throws(() => xdotoolKeys('ctrl+'), /No key/)
})

test('installed apps come from .desktop entries, and are matched by the name people say', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'jarvis-apps-'))
  const apps = join(dir, 'applications')
  mkdirSync(join(apps, 'org'), { recursive: true })
  const entry = (name, exec, extra = '') => `[Desktop Entry]\nType=Application\nName=${name}\nExec=${exec}\n${extra}`
  writeFileSync(join(apps, 'org.gnome.Calculator.desktop'), entry('Calculator', 'gnome-calculator', 'GenericName=Calculator\n'))
  writeFileSync(join(apps, 'code.desktop'), entry('Visual Studio Code', '/usr/share/code/code --unity-launch %F'))
  writeFileSync(join(apps, 'hidden.desktop'), entry('Hidden', 'hidden', 'NoDisplay=true\n'))
  writeFileSync(join(apps, 'org', 'gnome-Nested.desktop'), entry('Nested App', 'python3 /opt/nested/run.py'))
  writeFileSync(join(apps, 'link.desktop'), '[Desktop Entry]\nType=Link\nName=A link\nURL=https://example.com\n')
  const adapter = new LinuxAdapter({ env: { HOME: dir, XDG_DATA_HOME: dir, XDG_DATA_DIRS: join(dir, 'none'), PATH: '' } })
  const list = await adapter.installedApps()
  const names = list.map((a) => a.name).sort()
  assert.deepEqual(names, ['Calculator', 'Nested App', 'Visual Studio Code'])
  assert.equal(list.find((a) => a.name === 'Nested App').id, 'org-gnome-Nested.desktop')
  assert.equal(list.find((a) => a.name === 'Nested App').program, 'run.py')
  assert.equal(matchApp(list, 'vs code')?.name, 'Visual Studio Code')
  assert.equal(matchApp(list, 'the calculator app')?.name, 'Calculator')
  assert.equal(matchApp(list, 'spotify'), null)
  rmSync(dir, { recursive: true, force: true })
})

const desktop = process.platform === 'linux' && process.env.JARVIS_E2E_DESKTOP === '1'
test('a real desktop session: open, read, click, type, screenshot and close an app', { skip: desktop ? false : 'needs Linux with JARVIS_E2E_DESKTOP=1 (an X11 or Wayland session with AT-SPI)' }, async () => {
  const dir = mkdtempSync(join(tmpdir(), 'jarvis-e2e-'))
  const bin = join(dir, 'jarvis-test-app')
  copyFileSync(fileURLToPath(new URL('./e2e/jarvis-test-app', import.meta.url)), bin)
  chmodSync(bin, 0o755)
  mkdirSync(join(dir, 'applications'), { recursive: true })
  writeFileSync(join(dir, 'applications', 'jarvis-test-app.desktop'), `[Desktop Entry]\nType=Application\nName=Jarvis Test App\nExec=${bin}\n`)
  const env = { ...process.env, XDG_DATA_HOME: dir }
  const adapter = new LinuxAdapter({ env })
  const timings = {}
  const time = async (name, fn) => {
    const t0 = Date.now()
    const v = await fn()
    timings[name] = Date.now() - t0
    return v
  }
  try {
    const opened = await time('open', () => adapter.openApp('Jarvis Test App'))
    assert.ok(opened.ok, opened.message)
    await new Promise((r) => setTimeout(r, 1500))
    const running = await adapter.running()
    assert.ok(running.some((a) => a.name === 'Jarvis Test App'), JSON.stringify(running))
    const read = await time('read', () => adapter.readWindow('Jarvis Test App'))
    assert.match(read.text, /Hello from the test window/)
    assert.match(read.text, /Press me/)
    assert.match(await time('click', () => adapter.click('Jarvis Test App', 'Press me')), /pressed/)
    await new Promise((r) => setTimeout(r, 300))
    assert.match((await adapter.readWindow('Jarvis Test App')).text, /Button was pressed/)
    const typed = await time('type', () => adapter.typeText('Jarvis Test App', 'hello jarvis', { field: 'Message' }))
    assert.equal(typed, 'typed')
    assert.match((await adapter.readWindow('Jarvis Test App')).text, /hello jarvis/)
    assert.equal(await time('keys', () => adapter.pressKeys('Jarvis Test App', 'ctrl+a')), 'pressed')
    const front = await adapter.frontmost()
    assert.equal(front?.name, 'Jarvis Test App')
    const shot = await time('screenshot', () => adapter.screenshot({}))
    assert.ok(shot.image.length > 1000)
    const closed = await time('close', () => adapter.closeApp('Jarvis Test App'))
    assert.ok(closed.ok, closed.message)
    console.log(`# linux desktop actions (ms): ${JSON.stringify(timings)}`)
  } finally {
    await adapter.closeApp('Jarvis Test App', { force: true }).catch(() => {})
    rmSync(dir, { recursive: true, force: true })
  }
})
