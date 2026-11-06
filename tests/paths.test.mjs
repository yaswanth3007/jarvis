import test from 'node:test'
import assert from 'node:assert/strict'
import { jarvisPaths, keepaliveChannel, osName } from '../core/paths.mjs'

test('macOS keeps the folders Jarvis Voice has always used', () => {
  const p = jarvisPaths({ platform: 'darwin', env: {}, home: '/Users/u', user: 'u' })
  assert.equal(p.support, '/Users/u/Library/Application Support/JarvisVoice')
  assert.equal(p.logs, '/Users/u/Library/Logs/Jarvis')
  assert.equal(p.models, '/Users/u/Library/Caches/JarvisVoice/models')
  assert.equal(p.key, '/Users/u/Library/Application Support/JarvisVoice/bridge.key')
  assert.equal(p.control, '/Users/u/Library/Application Support/JarvisVoice/control.sock')
})

test('Windows uses the local (not roaming) profile and a per-user pipe', () => {
  const p = jarvisPaths({ platform: 'win32', env: { LOCALAPPDATA: 'C:\\Users\\u\\AppData\\Local' }, home: 'C:\\Users\\u', user: 'u' })
  assert.equal(p.support, 'C:\\Users\\u\\AppData\\Local\\Jarvis')
  assert.equal(p.logs, 'C:\\Users\\u\\AppData\\Local\\Jarvis\\Logs')
  assert.equal(p.key, 'C:\\Users\\u\\AppData\\Local\\Jarvis\\bridge.key')
  assert.equal(p.control, '\\\\.\\pipe\\jarvis-voice-u')
  assert.equal(keepaliveChannel('agent', p, 'win32'), '\\\\.\\pipe\\jarvis-keepalive-agent-u')
  const noEnv = jarvisPaths({ platform: 'win32', env: {}, home: 'C:\\Users\\u', user: 'a b/c' })
  assert.equal(noEnv.support, 'C:\\Users\\u\\AppData\\Local\\Jarvis')
  assert.equal(noEnv.control, '\\\\.\\pipe\\jarvis-voice-a_b_c')
})

test('Linux follows the XDG base directories, ignoring relative values', () => {
  const p = jarvisPaths({ platform: 'linux', env: { XDG_RUNTIME_DIR: '/run/user/1000' }, home: '/home/u', user: 'u' })
  assert.equal(p.support, '/home/u/.config/jarvis')
  assert.equal(p.logs, '/home/u/.local/state/jarvis/logs')
  assert.equal(p.cache, '/home/u/.cache/jarvis')
  assert.equal(p.control, '/run/user/1000/jarvis/control.sock')
  const custom = jarvisPaths({ platform: 'linux', env: { XDG_CONFIG_HOME: '/cfg', XDG_STATE_HOME: 'relative', XDG_CACHE_HOME: '/c' }, home: '/home/u', user: 'u' })
  assert.equal(custom.support, '/cfg/jarvis')
  assert.equal(custom.logs, '/home/u/.local/state/jarvis/logs')
  assert.equal(custom.cache, '/c/jarvis')
  assert.equal(custom.control, '/cfg/jarvis/control.sock')
})

test('JARVIS_HOME and friends move everything; no machine path is hard-coded', () => {
  const p = jarvisPaths({ platform: 'linux', env: { JARVIS_HOME: '/tmp/j', JARVIS_LOG_DIR: '/tmp/l', JARVIS_CACHE_DIR: '/tmp/c' }, home: '/home/u', user: 'u' })
  assert.deepEqual([p.support, p.logs, p.models, p.permissions], ['/tmp/j', '/tmp/l', '/tmp/c/models', '/tmp/j/permissions.json'])
  assert.equal(osName('darwin'), 'macos')
  assert.equal(osName('win32'), 'windows')
  assert.equal(osName('freebsd'), 'linux')
})
