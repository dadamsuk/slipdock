// The browser half of tools/e2e/release-build-link.sh (#3005).
//
//   node tools/e2e/release-build-link.mjs <login-url> <base-url> <board-id> <runner-token> <run-url> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, token, run, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 1400, height: 900 } })
// The run is on GitHub: answer it here, so the click needs no network.
await context.route('https://github.com/**', (r) => r.fulfill({ status: 200, contentType: 'text/html', body: '<title>the run</title>' }))
const page = await context.newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }
const count = (sel) => page.locator(sel).count()

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

// The runner's side, as the daemon speaks it.
async function runner(path, headers = {}, body = '') {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'text/plain', ...headers },
    body,
  })
  return res
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // Release now, from the Agentic Building page (its confirm is the app's own dialog).
  await open(`/boards/${board}/agentic`)
  await page.click('#board-release-now')
  await page.click('[data-confirm-ok]')
  await until('no release running on the Agentic page', async () =>
    (await page.locator('#board-release-line').innerText()).includes('A release is running'))
  if (await count('#board-release-running-run')) fail('a build linked before the job fired')
  console.log('ok: Release now started a release, with no build to link yet')

  // The board, open while the runner fires the release.
  await open(`/boards/${board}`)
  if (!(await page.locator('#release-banner-line').innerText()).includes('A release is running')) fail('no running release on the banner')
  if (await count('#release-running-run')) fail('the banner linked a build before the job fired')
  await shot('1-running')

  const claim = await runner('/api/runner/claim?wait=0', { 'x-runner-kinds': 'merge,release' })
  if (claim.status !== 200) fail(`the runner claimed nothing (${claim.status})`)
  const job = claim.headers.get('x-job-id')
  const done = await runner(`/api/runner/jobs/${job}/finish?exit=0`, {}, `release: run ${run}\n`)
  if (![200, 204].includes(done.status)) fail(`finishing the job answered ${done.status}`)

  await until('the banner never linked the build', async () => (await count('#release-running-run')) === 1)
  const link = page.locator('#release-running-run')
  if ((await link.getAttribute('href')) !== run) fail('the link goes elsewhere: ' + (await link.getAttribute('href')))
  if (!(await link.isVisible())) fail('the link is not visible')
  await shot('2-linked')
  console.log('ok: the banner linked the build as the job fired, without a reload')

  // One click: the run, in a tab of its own; the board stays.
  const [tab] = await Promise.all([context.waitForEvent('page'), link.click()])
  await tab.waitForLoadState()
  if (tab.url() !== run) fail('the click opened ' + tab.url())
  if (!page.url().includes(`/boards/${board}`)) fail('the board tab left the board')
  await tab.close()
  console.log('ok: one click opened the run in a new tab')

  await open(`/boards/${board}/agentic`)
  if ((await page.locator('#board-release-running-run').getAttribute('href')) !== run) fail('the Agentic page links no build')
  console.log('ok: the Agentic Building page links it too')
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
console.log('ok')
