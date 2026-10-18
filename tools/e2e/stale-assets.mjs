// The browser half of tools/e2e/stale-assets.sh: a tab opened before a
// deploy is told to reload, can put the bar away, and is up to date after
// following its Reload link.
//
//   node tools/e2e/stale-assets.mjs <login-url> <base-url>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base] = process.argv.slice(2)
const fail = (w) => { throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1200, height: 800 } })
page.on('pageerror', e => { if (!page.url().includes('/login')) console.log('PAGEERROR', e.message) })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
// The tab from before the deploy: its HTML names the old digests.
const old = async (route) => {
  const res = await route.fetch()
  const body = (await res.text()).replaceAll('/assets/js/app.js', '/assets/js/app-old.js').replaceAll('/assets/css/app.css', '/assets/css/app-old.css')
  await route.fulfill({ response: res, body })
}
await page.route(`${base}/work`, old)
await page.route(/app-old\.(js|css)/, async (r) => {
  const real = r.request().url().replace('app-old.', 'app.')
  await r.fulfill({ response: await r.fetch({ url: real }) })
})
await page.goto(`${base}/work`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
await page.locator('#stale-assets').waitFor({ timeout: 5000 })
const box = await page.locator('#stale-assets > div').boundingBox()
if (box.y > 100) fail(`bar not at the top: ${JSON.stringify(box)}`)
if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/stale-bar.png` })
// Close hides it.
await page.click('#stale-assets button[aria-label=close]')
await page.locator('#stale-assets').waitFor({ state: 'hidden', timeout: 3000 })
// Back again on reload while still stale; then the deploy is picked up.
await page.reload({ waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
await page.locator('#stale-assets').waitFor({ timeout: 5000 })
await page.unrouteAll()
await Promise.all([page.waitForNavigation(), page.click('#stale-assets-reload')])
await page.waitForSelector('.phx-connected')
await page.waitForTimeout(1000)
if (await page.locator('#stale-assets').count()) fail('still stale after Reload')
if (!page.url().endsWith('/work')) fail(`reload went to ${page.url()}`)
console.log('ok: bar shown, dismissed, and Reload picked up the new assets')
await browser.close()
