// The browser half of tools/e2e/home-tiles.sh (#1716): on the home page the
// Keystone tile's colour band is at most 8px tall and shows neither its code
// (kbe2e) nor its switcher key until hovered, its name's tooltip carries the
// code, and there is no "Add a new board" tile beside two boards. On the
// board, the header shows no code chip, the name's tooltip has the code, and
// the toolbar's Share button opens the settings panel on Sharing, and the
// ⋯ menu's Copy board code copies just the code.
//
//   node tools/e2e/home-tiles.mjs <login-url> <base-url> <kb-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, kb] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }
const shots = process.env.SHOTS
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  permissions: ['clipboard-read', 'clipboard-write'],
})
const page = await context.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

// Home.
await page.goto(`${base}/`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
const tile = page.locator(`#board-${kb}`)
await tile.waitFor()
await page.mouse.move(5, 5)
if (shots) await page.screenshot({ path: `${shots}/home-tiles-home.png` })

const band = await tile.locator('a > div').first().boundingBox()
if (!band) fail('no colour band on the tile')
if (band.height > 8) fail(`the tile's colour band is ${band.height}px tall`)
const text = await tile.innerText()
if (text.includes('kbe2e')) fail(`the tile shows its code before hover: ${JSON.stringify(text)}`)
const kbds = await tile.locator('kbd:visible').count()
if (kbds > 0) fail(`the tile shows ${kbds} key chip(s) before hover`)
const tip = await tile.locator('h2 [title]').first().getAttribute('title')
if (!tip || !tip.includes('kbe2e')) fail(`the tile name's tooltip is ${JSON.stringify(tip)}`)
if (await page.locator('#new-board-tile').count()) fail('"Add a new board" is shown beside two boards')
await tile.hover()
await page.waitForTimeout(300)
if (!(await tile.innerText()).includes('kbe2e')) fail('hovering the tile does not show its code')
// With the band thin, the hover buttons sit in the title row: never over the name.
const nameBox = await tile.locator('h2 > span[title]').boundingBox()
for (const sel of ['.board-handle', '.dropdown > [role=button]']) {
  const b = await tile.locator(sel).boundingBox()
  if (!b) fail(`${sel} not shown on hover`)
  if (b.x < nameBox.x + nameBox.width && nameBox.x < b.x + b.width && b.y < nameBox.y + nameBox.height && nameBox.y < b.y + b.height)
    fail(`${sel} covers the board's name`)
}
if (shots) await page.screenshot({ path: `${shots}/home-tiles-hover.png` })
// The tile's ⋯ menu copies the code too, without the markup's whitespace.
await tile.locator('.dropdown > [role=button]').click()
await page.locator(`#copy-code-${kb}`).click()
await page.locator(`#copy-code-${kb} [data-label]`, { hasText: 'Copied' }).waitFor()
const tileCopy = await page.evaluate(() => navigator.clipboard.readText())
if (tileCopy !== 'kbe2e') fail(`the tile's Copy board code copied ${JSON.stringify(tileCopy)}`)
await page.evaluate(() => navigator.clipboard.writeText(''))

// The board.
await page.goto(`${base}/boards/${kb}`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
await page.locator('#board-share-button').waitFor()
if (shots) await page.locator('header').screenshot({ path: `${shots}/home-tiles-board-header.png` })
if (shots) await page.screenshot({ path: `${shots}/home-tiles-board.png`, clip: { x: 0, y: 0, width: 1280, height: 160 } })
const header = await page.locator('header').innerText()
if (header.includes('kbe2e')) fail(`the board header shows the code: ${JSON.stringify(header)}`)
const nameTip = await page.locator('#board-name').getAttribute('title')
if (!nameTip || !nameTip.includes('kbe2e')) fail(`the board name's tooltip is ${JSON.stringify(nameTip)}`)
// The ⋯ menu's Copy board code puts exactly the code on the clipboard.
await page.locator('#board-actions .dropdown > [role=button]').click()
await page.locator('#board-share-copy-code').click()
await page.locator('#board-share-copy-code [data-label]', { hasText: 'Copied' }).waitFor()
const copied = await page.evaluate(() => navigator.clipboard.readText())
if (copied !== 'kbe2e') fail(`Copy board code copied ${JSON.stringify(copied)}`)
await page.keyboard.press('Escape')
await page.locator('body').click({ position: { x: 640, y: 600 } })
const share = page.locator('#board-share-button')
if (!(await share.isVisible())) fail('no Share button on the toolbar')
const box = await share.boundingBox()
if (box.x < 640) fail(`the Share button is not on the toolbar's right (x=${box.x})`)
await share.click()
await page.locator('#settings-panel-sharing').waitFor({ state: 'visible' })
const selected = await page.locator('#settings-tab-sharing').getAttribute('aria-selected')
if (selected !== 'true') fail('Share opened settings, but not on Sharing')
if (shots) await page.screenshot({ path: `${shots}/home-tiles-share.png` })
console.log(`ok: band ${band.height}px, no chips, tooltips carry the code, Copy board code copies it, Share at x=${Math.round(box.x)} opens Sharing`)
await browser.close()
