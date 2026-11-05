// The browser half of tools/e2e/date-sweep.sh (#1721).
//
//   node tools/e2e/date-sweep.mjs <login-url> <base-url> <board> <loose-card> <table-card>
import { createRequire } from 'node:module'
import { execSync } from 'node:child_process'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, loose, row] = process.argv.slice(2)
const shots = process.env.SHOTS
const failures = []
const check = (ok, what) => { if (!ok) failures.push(what); console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`) }
// What the database has: psql on the e2e database (lib.sh's DATABASE_URL).
const due = (id) => execSync(`psql "${process.env.DATABASE_URL}" -tAc "select coalesce(due_date::text, '') from cards where id = ${Number(id)}"`, { encoding: 'utf8' }).trim()
const settle = async (page, id, want) => {
  for (let i = 0; i < 40; i++) { if (due(id) === want) return true; await page.waitForTimeout(250) }
  return false
}
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-GB' })
const page = await ctx.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
}
// A digit on the focused field hands the keys to the native input (en-GB:
// dd/mm/yyyy); Tab commits it.
const typeInto = async (sel, digits) => {
  await page.locator(`${sel} [data-role=date-display]`).focus()
  await page.keyboard.type(digits)
  await page.keyboard.press('Tab')
}

// Timeline tray.
await open(`/boards/${board}/timeline?date=2030-01-15`)
const tray = `#schedule-date-${loose}`
await page.waitForSelector(tray)
check(await page.locator(`${tray} [data-role=date-text]`).innerText() === 'Set due date', 'tray: says Set due date')
if (shots) await page.screenshot({ path: `${shots}/date-sweep-tray.png` })
await typeInto(tray, '18012030')
check(await settle(page, loose, '2030-01-18'), `tray: stored ${due(loose)}`)
await page.waitForTimeout(500)
check(!(await page.locator(tray).count()), 'tray: the card left the tray')
check(await page.locator(`[id^=tl-bar-][id$="-${loose}"]`).count() > 0, 'tray: the card is on the grid')

// Table.
await open(`/boards/${board}/table?fields=title%2Cdue_date&rows=none`)
const cell = `#due-date-${row}`
await page.waitForSelector(cell)
check(await page.locator(`${cell} [data-role=date-text]`).innerText() === '15 Jan 2030', 'table: shows the due date')
check(await page.locator(`#due-${row} .chip`).count() === 0, 'table: no due chip beside the field')
check(await page.locator(`#due-${row} input[type=date]`).evaluate(el => getComputedStyle(el).opacity) === '0', 'table: the native input is hidden')
await typeInto(cell, '03032030')
check(await settle(page, row, '2030-03-03'), `table: stored ${due(row)}`)
check(await page.locator(`${cell} [data-role=date-text]`).innerText() === '3 Mar 2030', 'table: reads 3 Mar 2030')
if (shots) await page.screenshot({ path: `${shots}/date-sweep-table.png` })
await page.locator(`${cell} [data-role=date-clear]`).click()
check(await settle(page, row, ''), `table: cleared, stored "${due(row)}"`)
await open(`/boards/${board}/table?fields=title%2Cdue_date&rows=none`)
check(await page.locator(`${cell} [data-role=date-text]`).innerText() === 'Add date', 'table: the clear survives a reload')

await browser.close()
if (failures.length) { console.error(`\n${failures.length} failed`); process.exit(1) }
console.log('\nall passed')
