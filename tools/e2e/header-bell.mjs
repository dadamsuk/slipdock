// The browser half of tools/e2e/header-bell.sh: on a desktop-wide window,
// the bell, its glyph and its count are centred on the same line as the
// header's other icon buttons, give or take half a pixel, and the count
// does not stand above the row.
//
//   node tools/e2e/header-bell.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const fail = (w) => { throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
await page.goto(`${base}/boards/${board}`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
const middle = async (sel) => {
  const box = await page.locator(sel).boundingBox()
  if (!box) fail(`${sel} not shown`)
  return box.y + box.height / 2
}
await page.locator('#alerts-count').waitFor()
const bell = await middle('#alerts-bar > button')
// The glyphs too, not just their buttons: an icon can sit off its box's middle.
const glyph = async (sel) => middle(`${sel} span[class*=hero-]`)
const bellGlyph = await glyph('#alerts-bar > button')
const others = {}
for (const sel of ['#quick-add-open', '#favourites-link', '#account-menu > [role=button]']) others[sel] = await middle(sel)
if (process.env.SHOTS) await page.locator('header').screenshot({ path: `${process.env.SHOTS}/header-bell.png` })
for (const [sel, y] of Object.entries(others)) {
  if (Math.abs(y - bell) > 0.5) fail(`bell's middle at ${bell}, ${sel}'s at ${y}`)
}
for (const sel of ['#quick-add-open', '#favourites-link']) {
  const y = await glyph(sel)
  if (Math.abs(y - bellGlyph) > 0.5) fail(`bell's glyph middle at ${bellGlyph}, ${sel}'s at ${y}`)
}
const count = await middle('#alerts-count')
if (Math.abs(count - bell) > 0.5) fail(`count's middle at ${count}, the bell's at ${bell}`)
const top = async (sel) => (await page.locator(sel).boundingBox()).y
if (await top('#alerts-count') < await top('#favourites-link')) fail('the count stands above the row')
console.log(`ok: bell centred at ${bell}, with ${JSON.stringify(others)}`)
await browser.close()
