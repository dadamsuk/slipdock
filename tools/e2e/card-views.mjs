// The browser half of tools/e2e/card-views.sh (#2031).
//
//   node tools/e2e/card-views.mjs <login-url> <base-url> <board> <card-a> <card-b> <list-of-a>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, a, b, list] = process.argv.slice(2)
const shots = process.env.SHOTS
const failures = []
const check = (ok, what) => { if (!ok) failures.push(what) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })

const signIn = async (page) => {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
}
const open = async (page, path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
}
const has = async (page, sel) => (await page.locator(sel).count()) > 0
const prio = (id) => `#card-${id} [title^='Priority']`

const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await ctx.newPage()
await signIn(page)

// The defaults: high priority on both fronts.
await open(page, `/boards/${board}`)
check(await has(page, prio(a)) && await has(page, prio(b)), 'priority missing by default')

// The board's level, from the Display menu's link: hide Priority.
await page.locator('#display-menu [role=button]').first().click()
await page.locator('#edit-card-views').click()
await page.waitForSelector('#card-view-editor')
check(page.url().includes(`/card-views?board=${board}`), `editor link went to ${page.url()}`)
await page.locator('#element-priority button[data-value=hide]').click()
await page.waitForSelector('#element-priority button[data-value=hide][aria-pressed=true]')
check(!(await has(page, "#sample-card [title^='Priority']")), 'sample card still shows priority')
if (shots) await page.screenshot({ path: `${shots}/card-views-editor.png`, fullPage: true })

await open(page, `/boards/${board}`)
check(!(await has(page, prio(a))) && !(await has(page, prio(b))), 'board still shows priority after hiding it')

// Show all: every front element back, kept for the board after a reload.
await page.locator('#display-menu [role=button]').first().click()
await page.locator('#toggle-show-all').click()
await page.waitForSelector('#toggle-show-all[aria-pressed=true]')
check(await has(page, prio(a)), 'Show all did not bring priority back')
await open(page, `/boards/${board}`)
check(await has(page, prio(a)), 'Show all was not kept after a reload')
if (shots) await page.locator('#board-scroll').first().screenshot({ path: `${shots}/card-views-show-all.png` })
await page.locator('#display-menu [role=button]').first().click()
await page.locator('#toggle-show-all').click()
await page.waitForSelector('#toggle-show-all[aria-pressed=false]')

// A list's level: the opened card's description goes for that list's cards only.
await open(page, `/card-views?board=${board}&list=${list}`)
await page.locator('#card-view-tab-card').click()
await page.waitForSelector('#element-open-description')
await page.locator('#element-open-description button[data-value=hide]').click()
await page.waitForSelector('#element-open-description button[data-value=hide][aria-pressed=true]')
await open(page, `/boards/${board}/cards/${a}`)
check(!(await has(page, '#card-modal [data-section-key=d]')), "the list's card still shows its description")
await open(page, `/boards/${board}/cards/${b}`)
check(await has(page, '#card-modal [data-section-key=d]'), "another list's card lost its description")

await browser.close()
if (failures.length) { console.error('FAIL\n- ' + failures.join('\n- ')); process.exit(1) }
console.log('card-views: ok')
