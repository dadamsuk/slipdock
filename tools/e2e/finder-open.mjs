// The browser half of tools/e2e/finder-open.sh (#2019).
//
//   node tools/e2e/finder-open.mjs <login-url> <base-url> <board> <deep> <busy> <token>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, deep, busy, token] = process.argv.slice(2)
const problems = []
const fail = (w) => problems.push(w)
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({ viewport: { width: 1280, height: 800 } })
const page = await context.newPage()
page.on('pageerror', e => { if (!page.url().includes('/login')) fail(`page error: ${e.message}`) })

await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

// This browser remembers compact cards for the board, so every fresh mount
// of it restores them: the patch that used to close the card.
await page.evaluate((b) => localStorage.setItem(`slipdock:display:${b}:board`, JSON.stringify({density: 'compact'})), board)

// A tab from before a deploy: its HTML names the old digests.
const old = async (route) => {
  if (route.request().resourceType() !== 'document') return route.continue()
  const res = await route.fetch()
  const body = (await res.text()).replaceAll('/assets/js/app.js', '/assets/js/app-old.js').replaceAll('/assets/css/app.css', '/assets/css/app-old.css')
  await route.fulfill({ response: res, body })
}
const oldAssets = async (r) => {
  const real = r.request().url().replace('app-old.', 'app.')
  await r.fulfill({ response: await r.fetch({ url: real }) })
}

async function openBoard() {
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(800)
}

// Ctrl-O, the card's id, a click on its row: the finder's own navigate.
async function viaFinder(id) {
  await page.keyboard.press('Control+o')
  await page.locator('#palette-q-find').waitFor()
  await page.locator('#palette-q-find').fill(`#${id}`)
  const row = page.locator(`#palette-rows a[href="/boards/${board}/cards/${id}"]`)
  await row.waitFor({ timeout: 5000 })
  await row.click()
  await page.waitForURL(new RegExp(`/cards/${id}`))
  await page.waitForSelector('.phx-connected')
}

async function staysOpen(id, label, { stale }) {
  // Long enough for the restore's round trip, and for a crash and rejoin.
  await page.waitForTimeout(2500)
  const url = new URL(page.url())
  if (!url.pathname.endsWith(`/cards/${id}`)) fail(`${label}: left on ${url.pathname}${url.search}`)
  if (url.searchParams.get('density') !== 'compact') fail(`${label}: Display options not restored (${url.search})`)
  if (!(await page.locator('#card-modal').isVisible())) fail(`${label}: card panel closed`)
  const bar = await page.locator('#stale-assets').count()
  if (stale && !bar) fail(`${label}: stale tab, but no updated bar`)
  if (!stale && bar) fail(`${label}: up-to-date tab shows the updated bar`)
}

// 1. The stale tab.
await page.route(`${base}/boards/**`, old)
await page.route(/app-old\.(js|css)/, oldAssets)
await openBoard()
await viaFinder(deep)
await staysOpen(deep, 'stale tab, completed card deep in Done', { stale: true })
if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/finder-open-stale.png` })

// 2. A card being written to while it is open (a runner's comments).
await openBoard()
await viaFinder(busy)
for (let n = 1; n <= 3; n++) {
  const res = await fetch(`${base}/api/cards/${busy}/comments`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ body: `Runner step ${n}` })
  })
  if (!res.ok) fail(`comment ${n}: HTTP ${res.status}`)
  await page.waitForTimeout(400)
}
await staysOpen(busy, 'stale tab, card being written to', { stale: true })
if (!(await page.getByText('Runner step 3').count())) fail('the runner\'s last comment never showed')

// 3. Up to date: the same jumps, and no bar.
await page.unrouteAll()
{
  // The server's manifest names app-new; the up-to-date tab runs app-new.
  const fresh = async (route) => {
    if (route.request().resourceType() !== 'document') return route.continue()
    const res = await route.fetch()
    const body = (await res.text()).replaceAll('/assets/js/app.js', '/assets/js/app-new.js').replaceAll('/assets/css/app.css', '/assets/css/app-new.css').replaceAll('/assets/js/theme.js', '/assets/js/theme-new.js')
    await route.fulfill({ response: res, body })
  }
  await page.route(`${base}/boards/**`, fresh)
  await page.route(/(app|theme)-new\.(js|css)/, async (r) => {
    const real = r.request().url().replace(/-new\./, '.')
    await r.fulfill({ response: await r.fetch({ url: real }) })
  })
}
await openBoard()
if (await page.locator('#stale-assets').count()) fail('up-to-date board shows the updated bar')
await viaFinder(deep)
await staysOpen(deep, 'up-to-date tab, completed card deep in Done', { stale: false })
if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/finder-open-fresh.png` })

await browser.close()
if (problems.length) { console.log('FAIL\n- ' + problems.join('\n- ')); process.exit(1) }
console.log('ok: cards opened from Ctrl-O stay open; the updated bar shows only in the stale tab')
