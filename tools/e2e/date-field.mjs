// The browser half of tools/e2e/date-field.sh (#1720).
//
//   node tools/e2e/date-field.mjs <login-url> <base-url> <board> <card>
import { createRequire } from 'node:module'
import { execSync } from 'node:child_process'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, card] = process.argv.slice(2)
const shots = process.env.SHOTS
const failures = []
const check = (ok, what) => { if (!ok) failures.push(what); console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`) }
// What the database has: psql on the e2e database (lib.sh's DATABASE_URL).
const stored = () => execSync(`psql "${process.env.DATABASE_URL}" -tAc "select coalesce(due_date::text, '') from cards where id = ${Number(card)}"`, { encoding: 'utf8' }).trim()
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })

const signIn = async (page) => {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
}
const open = async (page) => {
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector(`#card-due-date-${card}`)
}
const field = `#card-due-date-${card}`
const words = (page) => page.locator(`${field} [data-role=date-text]`).innerText()
const settle = async (page, want) => {
  for (let i = 0; i < 40; i++) { if (stored() === want) return true; await page.waitForTimeout(250) }
  return false
}
// Types a date into the native input the way a person would: a digit on the
// focused display hands the keys over (en-GB: dd/mm/yyyy).
const typeDate = async (page, digits) => {
  await page.locator(`${field} [data-role=date-display]`).focus()
  await page.keyboard.type(digits)
  await page.keyboard.press('Tab')
}

// A context that records showPicker() calls instead of opening a popup a
// headless browser can't click.
const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'en-GB' })
await ctx.addInitScript(() => {
  window.__pickers = 0
  HTMLInputElement.prototype.showPicker = function () { window.__pickers++ }
})
const page = await ctx.newPage()
await signIn(page)
await open(page)

check(await words(page) === 'Add date', 'empty: says Add date')
check(await page.locator(`${field} input[type=date]`).evaluate(el => getComputedStyle(el).opacity) === '0', 'the native input is hidden')
check(!(await page.locator(`${field}[data-native]`).count()), 'showPicker present: no fallback')
const box = await page.locator(field).evaluate(el => {
  const s = getComputedStyle(el)
  return { h: el.getBoundingClientRect().height, font: s.fontSize, border: s.borderTopWidth }
})
check(box.h === 28 && box.font === '14px' && box.border === '1px', `the box is a field: ${JSON.stringify(box)}`)

await page.locator(`${field} [data-role=date-display]`).click()
check(await page.evaluate(() => window.__pickers) === 1, 'a click opens the picker')
await page.locator(`${field} [data-role=date-display]`).focus()
await page.keyboard.press('Enter')
check(await page.evaluate(() => window.__pickers) === 2, 'Enter opens the picker')
await page.keyboard.press(' ')
check(await page.evaluate(() => window.__pickers) === 3, 'Space opens the picker')

// Set.
await typeDate(page, '15012030')
check(await settle(page, '2030-01-15'), `set: stored ${stored()}`)
check(await words(page) === '15 Jan 2030', `set: reads ${await words(page)}`)
if (shots) await page.screenshot({ path: `${shots}/date-field-set.png` })

// Another edit re-renders the card back: the date stays.
await page.locator(`#card-modal textarea[name="card[title]"]`).first().fill('Book the venue early')
await page.waitForTimeout(800)
check(await words(page) === '15 Jan 2030', `after a re-render: reads ${await words(page)}`)

// Change.
await typeDate(page, '01022030')
check(await settle(page, '2030-02-01'), `change: stored ${stored()}`)
await open(page)
check(await words(page) === '1 Feb 2030', `change survives a reload: reads ${await words(page)}`)

// Clear.
await page.locator(`${field} [data-role=date-clear]`).click()
check(await settle(page, ''), `clear: stored "${stored()}"`)
check(await words(page) === 'Add date', 'clear: says Add date')
await open(page)
check(await words(page) === 'Add date', 'clear survives a reload')
check(await page.locator(`${field} [data-role=date-clear]`).isHidden(), 'no × with no date')

// No showPicker: the plain input shows and still saves.
// (Same context, so the same sign-in; a page script runs after the
// context's spy, so it takes showPicker away again.)
const p2 = await ctx.newPage()
await p2.addInitScript(() => { delete HTMLInputElement.prototype.showPicker })
await open(p2)
check(await p2.locator(`${field}[data-native]`).count() === 1, 'fallback: data-native set')
check(await p2.locator(`${field} input[type=date]`).isVisible(), 'fallback: the native input is visible')
check(await p2.locator(`${field} [data-role=date-display]`).isHidden(), 'fallback: the words are hidden')
await p2.locator(`${field} input[type=date]`).fill('2030-03-04')
await p2.locator(`${field} input[type=date]`).blur()
check(await settle(p2, '2030-03-04'), `fallback: stored ${stored()}`)
if (shots) await p2.screenshot({ path: `${shots}/date-field-native.png` })

await browser.close()
if (failures.length) { console.error(`\n${failures.length} failed`); process.exit(1) }
console.log('\nall passed')
