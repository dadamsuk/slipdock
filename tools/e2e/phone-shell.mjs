// The browser half of tools/e2e/phone-shell.sh (#1717).
//
//   node tools/e2e/phone-shell.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const measure = !!process.env.MEASURE
const problems = []
const fail = (w) => { if (measure) problems.push(w); else throw new Error(w) }
const shot = async (name) => { if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/${name}.png` }) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true })
const page = await context.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
}

// The last element of the page's scroll area, scrolled as far as it goes,
// must end above the dock's top edge.
const clearOfDock = async (name, scroller, last) => {
  const result = await page.evaluate(([scroller, last]) => {
    const s = document.querySelector(scroller)
    if (!s) return { error: `no ${scroller}` }
    s.scrollTop = s.scrollHeight
    const items = s.querySelectorAll(last)
    const el = items[items.length - 1]
    if (!el) return { error: `no ${last}` }
    const fab = document.querySelector('#mobile-fab').getBoundingClientRect()
    return { bottom: el.getBoundingClientRect().bottom, dockTop: fab.top }
  }, [scroller, last])
  if (result.error) return fail(`${name}: ${result.error}`)
  await page.waitForTimeout(100)
  console.log(`${name}: last ends at ${result.bottom.toFixed(1)}, dock starts at ${result.dockTop.toFixed(1)}`)
  if (result.bottom > result.dockTop) fail(`${name}: the last element (${result.bottom}) runs under the dock (${result.dockTop})`)
}

// 1. The board's toolbar is one row.
await open(`/boards/${board}`)
await shot('board')
const rows = await page.evaluate(() => {
  const bar = document.querySelector('#board-toolbar')
  if (!bar) return { error: 'no #board-toolbar' }
  const tops = new Set()
  for (const el of bar.children) {
    const r = el.getBoundingClientRect()
    if (r.width && r.height && getComputedStyle(el).display !== 'contents') tops.add(Math.round(r.top + r.height / 2))
  }
  return { rows: tops.size, height: bar.getBoundingClientRect().height }
})
console.log(`board toolbar: ${JSON.stringify(rows)}`)
if (rows.error) fail(rows.error)
else if (rows.rows !== 1) fail(`board toolbar is ${rows.rows} rows`)

// 2. The phone card's arrow names itself.
const arrows = await page.$$eval('[data-card-move], .hero-arrow-right-circle', (els) =>
  els.map((e) => e.closest('button, a')).filter(Boolean)
     .filter((b) => b.offsetParent !== null)
     .map((b) => ({ label: b.getAttribute('aria-label'), title: b.getAttribute('title') })))
console.log(`card arrows: ${arrows.length}, e.g. ${JSON.stringify(arrows[0])}`)
if (arrows.some((a) => !a.label || !a.title)) fail('a card arrow without an aria-label or title')

await clearOfDock('board', 'main [id^=cards-]', '.kanban-card')
// The list's own foot (Add, and the rest) ends above the dock too.
const boardBottom = await page.evaluate(() => ({
  board: document.querySelector('#board-scroll').getBoundingClientRect().bottom,
  dock: document.querySelector('#mobile-fab').getBoundingClientRect().top
}))
console.log(`board area: ${JSON.stringify(boardBottom)}`)
if (boardBottom.board > boardBottom.dock) fail(`the board runs under the dock: ${JSON.stringify(boardBottom)}`)

// 3. Account and My work scroll clear of the dock.
await open('/account')
await shot('account')
await clearOfDock('account', 'main .kanban-scroll', 'section, .card, [id]')
await open('/work')
await clearOfDock('work', 'main .kanban-scroll', 'li')
await shot('work')

// 4. Account → Profile stacks, and the name field is full width.
await open('/account')
await shot('profile')
const profile = await page.evaluate(() => {
  const name = document.querySelector('#profile-form input[name$="[name]"]')
  if (!name) return { error: 'no display name field' }
  const form = name.closest('form').getBoundingClientRect()
  const r = name.getBoundingClientRect()
  return { name: r.width, form: form.width }
})
console.log(`profile: ${JSON.stringify(profile)}`)
if (profile.error) fail(profile.error)
else if (profile.name < profile.form - 2) fail(`name field is ${profile.name}px in a ${profile.form}px form`)

// 5. The home list has no sideways overflow.
await open('/')
const compact = page.locator('button[phx-value-layout=compact], [phx-click=board_layout][phx-value-layout=compact]').first()
if (await compact.count()) { await compact.click(); await page.waitForTimeout(300) }
await shot('home-list')
const overflow = await page.evaluate(() => {
  const out = []
  for (const el of document.querySelectorAll('main *')) {
    if (el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).overflowX !== 'visible' && el.clientWidth > 0) out.push(`${el.tagName.toLowerCase()}#${el.id}.${[...el.classList].slice(0, 3).join('.')} ${el.scrollWidth}>${el.clientWidth}`)
  }
  return { page: document.documentElement.scrollWidth, out }
})
console.log(`home list: ${JSON.stringify(overflow)}`)
if (overflow.page > 390) fail(`home page is ${overflow.page}px wide`)
if (overflow.out.length) fail(`home list overflows: ${overflow.out.join('; ')}`)

if (measure) console.log(`problems:\n${problems.join('\n')}`)
else console.log('ok: phone toolbar, dock, profile, home list, card arrows')
await browser.close()
