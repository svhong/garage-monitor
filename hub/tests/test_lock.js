// Run with CHROMIUM_BIN=/path/to/chromium node --test hub/tests/test_lock.js
const { spawnSync } = require('node:child_process');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const html = readFileSync(join(__dirname, '../static/index.html'), 'utf8');

function checkInBrowser(scenario) {
  const setup = `
    const sessions = new Map([['gm-session', 'test-session']]);
    Object.defineProperty(window, 'localStorage', { value: {
      getItem: key => sessions.get(key), setItem: (key, value) => sessions.set(key, value),
      removeItem: key => sessions.delete(key)
    } });
    let calls = 0, release, logoutCalls = 0, expired = false;
    const machineData = { machines: [{ name: 'fixture-machine', age_s: 0, report: {} }] };
    window.fetch = async url => {
      if (url === 'api/logout') { logoutCalls++; return { ok: true }; }
      if (url === 'api/login') return { ok: true, json: async () => ({ token: 'new-session' }) };
      if (url !== 'api/machines') throw new Error('Unexpected request');
      calls++;
      if (expired) return { status: 401 };
      return { ok: true, json: () => calls === 2
        ? new Promise(resolve => { release = () => resolve(machineData); }) : Promise.resolve(machineData) };
    };
    const el = id => document.getElementById(id);
    const visible = id => getComputedStyle(el(id)).display !== 'none';
    const verify = (condition, message) => { if (!condition) throw new Error(message); };
    const wait = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));
    const cards = () => el('machines').querySelectorAll('.card').length;
    function checkLocked() {
      verify(visible('login'), 'Login is not visible');
      verify(!visible('machines'), 'Machine grid is still visible');
      verify(cards() === 0 && !el('summary').textContent, 'Stale dashboard data remains');
      verify(!visible('logout') && !visible('footer') && !visible('banner'), 'Dashboard chrome remains');
      verify(!sessions.has('gm-session'), 'Session is still saved');
    }
  `;
  const driver = `(async () => {
    try {
      await wait();
      verify(cards() === 1 && visible('machines') && visible('logout'), 'Fixture did not render');
      ${scenario}
      document.body.dataset.testResult = 'pass';
    } catch (error) { document.body.dataset.testResult = error.message; }
  })();`;
  const page = html.replace('<body>', `<body><script>${setup}</script>`)
    .replace('</body>', `<script>${driver}</script></body>`);
  const result = spawnSync(process.env.CHROMIUM_BIN || 'chromium', [
    '--headless', '--disable-gpu', '--no-first-run', '--virtual-time-budget=10000', '--dump-dom',
    ...(process.env.CHROMIUM_NO_SANDBOX === '1' ? ['--no-sandbox'] : []),
    'data:text/html;base64,' + Buffer.from(page).toString('base64'),
  ], { encoding: 'utf8', timeout: 15000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.match(/<body[^>]*data-test-result="([^"]+)"/)?.[1], 'pass');
}

test('Lock clears the dashboard, ignores pending poll data, and allows unlock', () => {
  checkInBrowser(`
    await wait(2010);
    verify(typeof release === 'function', 'No pending poll response');
    el('logout').click();
    checkLocked();
    verify(logoutCalls === 1, 'Server logout was not requested');
    release();
    await wait(2300);
    checkLocked();
    verify(calls === 2, 'Polling resumed while locked');
    el('login').dispatchEvent(new Event('submit', { cancelable: true }));
    await wait();
    verify(cards() === 1 && visible('machines') && !visible('login'), 'Unlock did not restore dashboard');
  `);
});

test('An expired session also clears the dashboard and stops polling', () => {
  checkInBrowser(`
    expired = true;
    await wait(4300);
    checkLocked();
    verify(calls === 2, 'Polling resumed after session expiry');
  `);
});
