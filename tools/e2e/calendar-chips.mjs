// The browser half of tools/e2e/calendar-chips.sh (#1733). On the demo
// board's calendar:
//   - at 1440px, month and week, every chip's title comes first and shows
//     at least 20 characters (or all of a shorter title) before any
//     decoration;
//   - every chip's tooltip (title attribute) starts with the full title;
//   - on a wider chip (a 2560px window) the decorations are back;
//   - no chip carries an arrow without a label.
//
//   node tools/e2e/calendar-chips.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (w) => { throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (query, width) => {
  await page.setViewportSize({ width, height: 900 })
  await page.goto(`${base}/boards/${board}/calendar${query}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#calendar .cal-chip')
}

// Per chip in the grid (not the no-date tray): its title, its tooltip, how
// many characters of the title can be seen, whether anything visible sits
// before the title, which decorations show, and any unlabelled arrow.
const measure = () => page.evaluate(() => {
  const shown = (el) => {
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'
  }
  return [...document.querySelectorAll('#calendar .cal-chip')].filter(shown).map((chip) => {
    const title = chip.querySelector('.cal-chip-title') || chip.querySelector('span.truncate')
    const text = title.textContent.trim()
    const box = title.getBoundingClientRect()
    // The ellipsis covers the last character that is cut, so a character
    // counts only if it ends a character's width short of the clip.
    const node = [...title.childNodes].find((n) => n.nodeType === 3 && n.textContent.trim())
    const offset = node.textContent.indexOf(text[0])
    const range = document.createRange()
    let seen = 0
    const clipped = title.scrollWidth > title.clientWidth + 1
    for (let i = 0; i < text.length; i++) {
      range.setStart(node, offset + i); range.setEnd(node, offset + i + 1)
      const r = range.getBoundingClientRect()
      if (r.right <= box.right - (clipped ? r.width + 1 : -0.5)) seen++
      else break
    }
    const others = [...chip.children].filter((c) => c !== title && shown(c))
    const before = others.filter((c) => c.getBoundingClientRect().left < box.left - 0.5)
    const deco = [...chip.querySelectorAll('.cal-chip-deco')].filter(shown)
    const arrows = [...chip.querySelectorAll('.hero-arrow-long-right, .hero-arrow-right')]
      .filter(shown)
      .filter((a) => !a.closest('[aria-label]'))
    return { id: chip.id, text, tooltip: chip.getAttribute('title') || '', seen, before: before.length, deco: deco.length, arrows: arrows.length }
  })
})

const check = (chips, where, least = 5) => {
  if (chips.length < least) fail(`${where}: only ${chips.length} chips on the calendar`)
  for (const c of chips) {
    const want = Math.min(20, c.text.length)
    if (c.seen < want) fail(`${where}: "${c.text}" shows ${c.seen} characters, under ${want}`)
    if (c.before) fail(`${where}: "${c.text}" has ${c.before} decoration(s) before its title`)
    if (!c.tooltip.startsWith(c.text)) fail(`${where}: "${c.text}"'s tooltip is "${c.tooltip}"`)
    if (c.arrows) fail(`${where}: "${c.text}" carries an unlabelled arrow`)
  }
}

const worst = 'Reconcile quarterly invoices with the ledger export'
const results = {}

await open('', 1440)
if (shots) await page.screenshot({ path: `${shots}/calendar-month-1440.png` })
const month = await measure()
results.month1440 = month.map(({ text, seen, deco }) => ({ text, seen, deco }))
check(month, 'month at 1440')
const long = month.find((c) => c.text === worst) ?? fail('no long-titled chip in the month')
if (!/Priority: Critical/.test(long.tooltip) || !/Tags: /.test(long.tooltip) || !/Blocked/.test(long.tooltip))
  fail(`the tooltip lacks the metadata: "${long.tooltip}"`)

await open('?unit=week', 1440)
if (shots) await page.screenshot({ path: `${shots}/calendar-week-1440.png` })
const week = await measure()
results.week1440 = week.length
check(week, 'week at 1440', 2)
week.find((c) => c.text === worst) ?? fail('no long-titled chip in the week')

await open('', 2560)
if (shots) await page.screenshot({ path: `${shots}/calendar-month-2560.png` })
const wide = await measure()
check(wide, 'month at 2560')
const wideLong = wide.find((c) => c.text === worst) ?? fail('no long-titled chip at 2560')
if (wideLong.deco === 0) fail('the decorations do not come back on a wide chip')
results.wideDecorations = wideLong.deco

console.log(JSON.stringify(results, null, 1))
console.log('calendar-chips: OK')
await browser.close()
