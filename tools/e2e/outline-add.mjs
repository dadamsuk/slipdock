// The browser half of tools/e2e/outline-add.sh (#2024).
//
//   node tools/e2e/outline-add.mjs <login-url> <base-url> <board-id>
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
await page.goto(`${base}/boards/${board}/outline`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')

if (await page.locator('form[id^=outline-add-]').count()) fail('an add-a-subcard row shows before any + is pressed')
if (await page.locator('#outline > .ol-row:not(.ol-head)').count() !== 251) fail('page 1 is not 250 cards and one child')
if ((await page.locator('#outline-page-of').innerText()).trim() !== 'Page 1 of 2') fail('no "Page 1 of 2"')

// Rows are tighter: a plain row under 36px (37 with py-1.5, 33 with py-1).
const rowH = (await page.locator('#outline > .ol-row:not(.ol-head)').nth(5).boundingBox()).height
if (rowH >= 36) fail(`a row is ${rowH}px high`)

// The + shows on hover, opens a focused row, and Enter adds under that card.
const row = page.locator('#outline > .ol-row[data-level="0"]').first()
const id = (await row.getAttribute('id')).replace('ol-', '')
const plus = page.locator(`#ol-add-sub-${id}`)
const op0 = await plus.evaluate((el) => getComputedStyle(el).opacity)
await row.hover()
await page.waitForTimeout(300)
const op1 = await plus.evaluate((el) => getComputedStyle(el).opacity)
if (!(Number(op0) < 0.1 && Number(op1) > 0.9)) fail(`+ opacity ${op0} at rest, ${op1} on hover`)
await plus.click()
const input = page.locator(`#outline-add-${id} input[name=title]`)
await input.waitFor()
await page.waitForFunction((sel) => document.activeElement === document.querySelector(sel), `#outline-add-${id}-title`)
await input.fill('Added from the icon')
await input.press('Enter')
await page.locator('#outline .ol-row[data-level="1"]', { hasText: 'Added from the icon' }).waitFor()
if (await input.inputValue() !== '') fail('the box was not cleared for the next one')
if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/outline-add.png` })

// Next at the bottom: page 2, scrolled to its top.
const scroller = page.locator('#outline-scroll')
await scroller.evaluate((el) => { el.scrollTop = el.scrollHeight })
await page.locator('#outline-next').click()
await page.locator('#outline-page-of', { hasText: 'Page 2 of 2' }).waitFor()
const top = await scroller.evaluate((el) => el.scrollTop)
if (top !== 0) fail(`page 2 starts scrolled to ${top}`)
if (!(await page.locator('#outline .ol-row', { hasText: 'Card 251' }).count())) fail('Card 251 not on page 2')
console.log(`ok: row ${rowH}px, + on hover, subcard added, page 2 at top`)
await browser.close()
