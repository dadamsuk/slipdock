// The browser half of tools/e2e/ledger.sh (#2013).
//
//   node tools/e2e/ledger.mjs <login-url> <base-url> <board-id>
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

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(400)
}
const theme = (t) => page.evaluate((t) => document.documentElement.setAttribute('data-theme', t), t)
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }

await open(`/boards/${board}/ledger?since=3`)
const lines = await page.locator('.ledger-line').count()
if (lines !== 5) fail(`${lines} lines, not 5`)
const days = await page.locator('.ledger-day').count()
if (days < 2) fail(`${days} days`)

// Bars: segments fill each bar, a longer lead time draws a longer bar.
const bars = await page.$$eval('.ledger-line [data-role=phase-bar]', (els) => els.map((el) => {
  const bar = el.querySelector('.ledger-bar')
  const segs = [...bar.querySelectorAll('.ledger-seg')]
  const sum = segs.reduce((n, s) => n + s.getBoundingClientRect().width, 0) + 2 * (segs.length - 1)
  return { id: el.id, track: el.getBoundingClientRect().width, bar: bar.getBoundingClientRect().width, sum, segs: segs.length }
}))
if (bars.length !== 5) fail(`${bars.length} bars`)
for (const b of bars) if (Math.abs(b.sum - b.bar) > 2) fail(`${b.id}: segments ${b.sum}px fill a ${b.bar}px bar`)
const widths = bars.map((b) => b.bar)
const [longest, shortest] = [Math.max(...widths), Math.min(...widths)]
if (shortest < 0.15 * bars[0].track) fail(`the 12-minute bar is a sliver: ${shortest}px`)
if (longest > 0.9 * bars[0].track) fail(`the 3-day bar fills the track: ${longest}px`)
console.log(`ok: ${lines} lines over ${days} days; bars ${Math.round(shortest)}–${Math.round(longest)}px of ${Math.round(bars[0].track)}`)

// Waiting is hatched, work solid.
const fills = await page.$$eval('.ledger-line .ledger-seg', (els) => els.map((e) => ({ phase: e.dataset.phase, img: getComputedStyle(e).backgroundImage })))
const waiting = fills.filter((f) => ['backlog', 'waiting_for_runner', 'waiting_on_person', 'verification_wait'].includes(f.phase))
const working = fills.filter((f) => ['build', 'ci', 'verify', 'rework', 'merge', 'deploy'].includes(f.phase))
if (waiting.some((f) => !/repeating-linear-gradient/.test(f.img))) fail('a waiting phase is not hatched')
if (working.some((f) => f.img !== 'none')) fail('a working phase is hatched')
console.log(`ok: ${waiting.length} waiting segments hatched, ${working.length} working solid, phases: ${[...new Set(fills.map((f) => f.phase))].join(', ')}`)

// The tooltip on hover and on focus.
const seg = page.locator('.ledger-line .ledger-seg').first()
await seg.hover()
const tip = await seg.evaluate((el) => getComputedStyle(el, '::after').display)
if (tip !== 'block') fail(`hovering shows no tooltip (${tip})`)
await page.mouse.move(0, 0)
await seg.focus()
const tipFocus = await seg.evaluate((el) => [getComputedStyle(el, '::after').display, getComputedStyle(el, '::after').content])
if (tipFocus[0] !== 'block' || !/·/.test(tipFocus[1])) fail(`focus shows no tooltip: ${tipFocus}`)
console.log(`ok: a segment's time shows on hover and focus: ${tipFocus[1]}`)
await seg.blur()

// Each day's summary.
const summary = await page.locator('[data-role=day-summary]').first().innerText()
if (!/\d+ shipped/.test(summary) || !/median lead time/.test(summary)) fail(`day summary: ${summary}`)
if ((await page.locator('[id^=ledger-day-bar-]').count()) < 2) fail('a day has no bar')
console.log(`ok: day summary "${summary.replace(/\s+/g, ' ')}"`)

for (const t of ['light', 'dark']) {
  await theme(t)
  await page.waitForTimeout(200)
  await shot(`ledger-${t}-1440`)
  await page.setViewportSize({ width: 1440, height: 2600 })
  await page.waitForTimeout(200)
  await shot(`ledger-${t}-1440-full`)
  await page.setViewportSize({ width: 1440, height: 900 })
}
// A tooltip showing, for the card.
await theme('light')
await page.locator('.ledger-line').first().locator('.ledger-seg').last().hover()
await page.waitForTimeout(150)
if (shots) await page.locator('.ledger-line').first().screenshot({ path: `${shots}/ledger-line-tooltip-light.png` })

// Phone width: nothing wider than the screen, tooltips included.
await page.setViewportSize({ width: 390, height: 844 })
await open(`/boards/${board}/ledger?since=3`)
for (const t of ['light', 'dark']) {
  await theme(t)
  await page.waitForTimeout(200)
  for (const s of await page.locator('.ledger-seg').all()) {
    await s.focus()
    const r = await s.evaluate((el) => {
      const a = getComputedStyle(el, '::after')
      // The tooltip hangs from its containing block: the segment, or on a
      // phone (where the segment is static) the track.
      const cb = getComputedStyle(el).position === 'static' ? el.offsetParent : el
      const box = cb.getBoundingClientRect()
      const w = parseFloat(a.width)
      const left = a.left !== 'auto' ? box.left + parseFloat(a.left) : box.right - parseFloat(a.right) - w
      return { left, right: left + w }
    })
    if (r.left < 0 || r.right > 390) fail(`${t}: a tooltip runs off the phone: ${JSON.stringify(r)}`)
  }
  await page.evaluate(() => { document.activeElement?.blur(); document.getElementById('ledger-shell').scrollTop = 0 })
  await page.waitForTimeout(150)
  const wide = await page.evaluate(() => document.documentElement.scrollWidth)
  const shell = await page.$eval('#ledger-shell', (el) => el.scrollWidth - el.clientWidth)
  if (wide > 390 || shell > 0) fail(`${t}: wider than the phone (${wide}, shell +${shell})`)
  await shot(`ledger-${t}-390`)
  await page.setViewportSize({ width: 390, height: 3400 })
  await page.waitForTimeout(200)
  await shot(`ledger-${t}-390-full`)
  await page.setViewportSize({ width: 390, height: 844 })
}
console.log('ok: no sideways scroll at 390, light or dark, tooltips inside the screen')

await browser.close()
console.log('ok')
