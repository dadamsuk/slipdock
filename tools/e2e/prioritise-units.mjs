// The browser half of tools/e2e/prioritise-units.sh (#1734).
//   - Prioritise: every unit sits under 8px after its value's last digit;
//     every cell's content is centred on its row (within 1.5px); the
//     numbers are tabular Inter, not the mono font.
//   - Narrative: the card's lines don't repeat its title, and its four
//     field changes read as one line.
//
//   node tools/e2e/prioritise-units.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board, card] = process.argv.slice(2)
const shots = process.env.SHOTS
// SOFT=1 reports every failure and carries on (for before-shots).
const fail = (w) => { if (process.env.SOFT) console.log('FAIL', w); else throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

await page.goto(`${base}/boards/${board}/prioritise`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
await page.waitForSelector(`#prio-${card}`)
if (shots) await page.screenshot({ path: `${shots}/prioritise.png` })

const m = await page.evaluate((card) => {
  const row = document.getElementById(`prio-${card}`)
  // The gap from the end of the typed digits to the unit: the digits are
  // measured with a canvas in the input's own font, since the input's box
  // can be wider than what it shows.
  const cx = document.createElement('canvas').getContext('2d')
  const gaps = [...row.querySelectorAll('form')].flatMap((form) => {
    const input = form.querySelector('input[type=number]')
    const unit = form.querySelector('[data-unit]')
    if (!input || !unit || !input.value) return []
    const s = getComputedStyle(input)
    cx.font = `${s.fontWeight} ${s.fontSize} ${s.fontFamily}`
    const r = input.getBoundingClientRect()
    const textEnd = s.textAlign === 'right' || s.textAlign === 'end'
      ? r.right - parseFloat(s.paddingRight) - parseFloat(s.borderRightWidth)
      : r.left + parseFloat(s.borderLeftWidth) + parseFloat(s.paddingLeft) + cx.measureText(input.value).width
    return [{ value: input.value, unit: unit.textContent.trim(), gap: unit.getBoundingClientRect().left - textEnd }]
  })
  // Each cell's content against the row's centre line.
  const rr = row.getBoundingClientRect()
  const mid = rr.top + rr.height / 2
  const offsets = [...row.children].map((td, i) => {
    const kids = [...td.children].filter((k) => k.offsetParent !== null)
    const el = kids[0] || td
    const b = el.getBoundingClientRect()
    return { i, tag: el.tagName, off: b.top + b.height / 2 - mid, valign: getComputedStyle(td).verticalAlign }
  })
  const fontOf = (el) => getComputedStyle(el)
  const rank = fontOf(row.children[0])
  const votes = row.querySelector('[title="Votes from everyone"]')
  const formula = row.children[row.children.length - 1]
  return {
    gaps, offsets,
    fonts: [rank, fontOf(votes), fontOf(formula)].map((s) => ({ family: s.fontFamily, num: s.fontVariantNumeric })),
    inputNum: getComputedStyle(row.querySelector('input[type=number]')).fontVariantNumeric,
    // A number box shares the row's text size, so its digits sit on the row's line.
    sizes: [row.querySelector('input[type=number]'), row.querySelector('[data-unit]'), row.children[1]].map((e) => getComputedStyle(e).fontSize)
  }
}, card)
console.log(JSON.stringify(m))

if (m.gaps.length < 3) fail(`expected at least 3 values with units, saw ${m.gaps.length}`)
for (const g of m.gaps) if (!(g.gap >= 0 && g.gap < 8)) fail(`"${g.value}" sits ${g.gap.toFixed(1)}px from "${g.unit}" (want 0–8px)`)
if (new Set(m.sizes).size !== 1) fail(`number, unit and title sizes differ: ${m.sizes}`)
for (const o of m.offsets) if (Math.abs(o.off) > 1.5) fail(`cell ${o.i} (${o.tag}) is ${o.off.toFixed(1)}px off the row's centre`)
for (const f of [...m.fonts, { family: 'Inter', num: m.inputNum }]) {
  if (/mono/i.test(f.family)) fail(`a number is set in ${f.family}`)
  if (!/tabular-nums/.test(f.num)) fail(`a number is not tabular (${f.num})`)
}

await page.goto(`${base}/boards/${board}/narrative`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
const story = page.locator('[id^=story-]', { hasText: 'Dark mode for the dashboard' }).first()
await story.waitFor()
if (shots) await page.screenshot({ path: `${shots}/narrative.png` })
const lines = await story.locator('li').allInnerTexts()
console.log(JSON.stringify(lines))
if (lines.some((l) => l.includes('Dark mode for the dashboard'))) fail('a narrative line repeats the card title')
const folded = lines.filter((l) => /Reach 4000 people, Impact 3, Confidence 80%, Effort 3 weeks/.test(l))
if (folded.length !== 1) fail(`expected one folded line for the four field changes, saw ${folded.length}`)

await browser.close()
console.log('prioritise-units: ok')
