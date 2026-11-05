// The browser half of tools/e2e/priority-start.sh (#1709). Priority is one
// icon family, signal bars, with a tooltip, in every view; medium is off the
// card face, the outline and the calendar; the start chip and the card back
// say in words when a card starts.
//
//   node tools/e2e/priority-start.mjs <login-url> <base-url> <board> <low> <medium> <high> <critical>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, low, med, high, crit] = process.argv.slice(2)
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
  await page.mouse.move(0, 0)
}
const count = (page, sel) => page.locator(sel).count()
const title = async (page, sel) => {
  const loc = page.locator(sel).first()
  return (await loc.count()) ? loc.getAttribute('title') : null
}
// The bars a priority mark draws: how many, how many lit, and whether they are visible.
const bars = async (page, sel) => {
  const loc = page.locator(`${sel} [data-role=priority-bars]`).first()
  if (!(await loc.count())) return null
  return loc.evaluate((svg) => {
    const rects = [...svg.querySelectorAll('rect')]
    const box = svg.getBoundingClientRect()
    return {
      total: rects.length,
      lit: rects.filter((r) => r.getAttribute('opacity') === '1').length,
      w: box.width, h: box.height,
    }
  })
}
const prios = [['low', low, 'Low', 1], ['medium', med, 'Medium', 2], ['high', high, 'High', 3], ['critical', crit, 'Critical', 4]]

const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await ctx.newPage()
await signIn(page)

// The card face: bars with a tooltip, medium left off, start chip in words.
await open(page, `/boards/${board}?show=tags,priority,flags,start_date`)
for (const [p, id, label, level] of prios) {
  const sel = `#card-${id} [data-role=priority]`
  if (p === 'medium') {
    check((await count(page, sel)) === 0, 'face: medium priority shown')
    continue
  }
  check((await title(page, sel)) === `Priority: ${label}`, `face: ${p} tooltip ${await title(page, sel)}`)
  const b = await bars(page, `#card-${id}`)
  check(b && b.total === 4 && b.lit === level && b.w > 8 && b.h > 8, `face: ${p} bars ${JSON.stringify(b)}`)
}
const startTitle = async (id) => title(page, `#card-${id} [data-role=start]`)
check(((await startTitle(low)) || '').startsWith('Starts in 11 days'), `start early: ${await startTitle(low)}`)
check(((await startTitle(high)) || '').startsWith('Starts today'), `start on time: ${await startTitle(high)}`)
check(((await startTitle(crit)) || '').startsWith('Started 11 days late'), `start late: ${await startTitle(crit)}`)
check((await count(page, `#card-${low} [data-role=start] .hero-play`)) === 0, 'start chip still draws the play triangle')
if (shots) await page.screenshot({ path: `${shots}/face.png`, clip: { x: 0, y: 0, width: 1440, height: 700 } })

// The filter menu: every priority, medium included, as bars.
await page.locator('[title=Filter]').first().click()
const menu = '[data-role=filter-priority]'
for (const [p, , label, level] of prios) {
  const sel = `${menu} [data-priority=${p}]`
  check((await title(page, sel)) === `Priority: ${label}`, `filter: ${p} tooltip`)
  const b = await bars(page, `${menu} button:has([data-priority=${p}])`)
  check(b && b.lit === level, `filter: ${p} bars ${JSON.stringify(b)}`)
}
check((await count(page, '[data-role=filter-due] .hero-calendar')) === 1, 'filter: due icon differs from the face')
if (shots) await page.screenshot({ path: `${shots}/filter.png`, clip: { x: 0, y: 0, width: 1440, height: 700 } })
await page.keyboard.press('Escape')

// The start overrun chip says it in words too.
await open(page, `/boards/${board}?show=priority,due_date`)
const slip = await title(page, `#card-${crit} [data-role=start-slip]`)
check((slip || '').startsWith('Started 11 days late.'), `slip chip: ${slip}`)

// The table lists every priority, so medium has its bars there.
await open(page, `/boards/${board}/table`)
for (const [p, id, label, level] of prios) {
  const b = await bars(page, `#prio-${id}`)
  check(b && b.lit === level, `table: ${p} bars ${JSON.stringify(b)}`)
  check((await title(page, `#prio-${id} [data-role=priority]`)) === `Priority: ${label}`, `table: ${p} tooltip`)
}

// The outline and the calendar leave medium off.
await open(page, `/boards/${board}/outline`)
check((await count(page, `#ol-${med} [data-role=priority]`)) === 0, 'outline: medium shown')
check((await bars(page, `#ol-${crit}`))?.lit === 4, 'outline: critical bars missing')
await open(page, `/boards/${board}/calendar`)
check((await count(page, `.cal-chip[data-id='${med}'] [data-role=priority]`)) === 0, 'calendar: medium shown')
check((await bars(page, `.cal-chip[data-id='${high}']`))?.lit === 3, 'calendar: high bars missing')

// The card back says the start in words, with the same icon pair.
await open(page, `/boards/${board}/cards/${crit}`)
const words = page.locator('[data-role=start-words]').first()
check((await words.count()) && (await words.textContent()).includes('Started 11 days late'), 'card back: start words missing')
check((await count(page, '[data-prop=start] [data-role=prop-label] .hero-arrow-right-circle')) === 1, 'card back: start icon')
check((await count(page, '[data-prop=due] [data-role=prop-label] .hero-calendar')) === 1, 'card back: due icon')
if (shots) await page.screenshot({ path: `${shots}/card-back.png` })

await browser.close()
if (failures.length) { console.error('FAIL:\n- ' + failures.join('\n- ')); process.exit(1) }
console.log('ok: signal bars with tooltips on face, filter, table, outline and calendar; medium off face/outline/calendar; start in words on the chip, the overrun chip and the card back')
