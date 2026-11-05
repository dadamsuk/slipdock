// The browser half of tools/e2e/toolbar-one-row.sh (#1711).
//
//   node tools/e2e/toolbar-one-row.mjs <login-url> <base-url> <board-id>
//
// MEASURE_ONLY=1 prints the measurements without failing (for a before shot).
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const problems = []
const fail = (w) => problems.push(w)
const shots = process.env.SHOTS
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })

const views = [
  ['board', ''], ['swimlanes', '/swimlanes'], ['table', '/table'], ['timeline', '/timeline'],
  ['calendar', '/calendar'], ['outline', '/outline'], ['narrative', '/narrative'], ['prioritise', '/prioritise'],
]
// The one order every toolbar keeps; `nav` is there only on the dated views,
// `view-options` only on views with controls of their own, `select` only on
// the board.
const ORDER = ['switcher', 'search', 'filter', 'nav', 'view-options', 'display', 'count', 'select', 'views', 'actions']
// On a phone the timeline's and calendar's "‹ Today › Oct – Jan" is a row of
// its own below the toolbar's, as it was before #1711; nothing else is.
const PHONE_NAV = ['timeline', 'calendar']

// The sign-in link works once, so one page, resized between the sizes.
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

async function open(suffix) {
  await page.goto(`${base}/boards/${board}${suffix}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  // The fold is measured after mount and after the fonts have loaded.
  await page.evaluate(() => document.fonts.ready)
  await page.waitForTimeout(250)
}

// The toolbar's box, its row height and the order of its parts, both in the
// DOM and as drawn (left to right, for the parts that show).
const measure = () => page.evaluate(() => {
  // After #1711 every view's toolbar wears the ToolbarFold hook; before it,
  // the board's is #board-toolbar and the others' the row holding the switcher.
  const bar = document.querySelector('[phx-hook=ToolbarFold]') || document.querySelector('#board-toolbar') || document.querySelector('#view-menu').closest('.border-b')
  const switcher = document.querySelector('#view-menu [role=button]')
  const box = (el) => {
    const own = el.getBoundingClientRect()
    if (own.width > 0 && own.height > 0 && getComputedStyle(el).visibility !== 'hidden') return own
    for (const d of el.querySelectorAll('*')) {
      const r = d.getBoundingClientRect()
      if (r.width > 0 && r.height > 0 && !d.closest('.dropdown-content, [popover], [data-role=view-options-panel]')) return r
    }
    return null
  }
  const parts = [...bar.querySelectorAll('[data-tb]')].filter((el) => !el.parentElement.closest('[data-tb]'))
  const drawn = parts.map((el) => ({ tb: el.dataset.tb, r: box(el) })).filter((p) => p.r)
  const cs = getComputedStyle(bar)
  return {
    height: bar.getBoundingClientRect().height,
    oneRow: switcher.getBoundingClientRect().height + parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom) + parseFloat(cs.borderBottomWidth) + 2,
    bottom: bar.getBoundingClientRect().bottom,
    folded: bar.hasAttribute('data-folded'),
    dom: parts.map((el) => el.dataset.tb),
    drawn: drawn.map((p) => ({ tb: p.tb, x: Math.round(p.r.left), y: Math.round(p.r.top + p.r.height / 2) })),
  }
})

function checkOrder(label, m, wide) {
  const want = ORDER.filter((t) => m.dom.includes(t))
  if (m.dom.join() !== want.join()) fail(`${label}: toolbar order ${m.dom.join(' · ') || '(no marked parts)'}, want ${want.join(' · ')}`)
  for (const t of ['switcher', 'search', 'filter', 'display', 'views']) if (!m.dom.includes(t)) fail(`${label}: no ${t} in the toolbar`)
  if (!wide) return
  for (let i = 1; i < m.drawn.length; i++)
    if (m.drawn[i].x < m.drawn[i - 1].x) fail(`${label}: ${m.drawn[i].tb} is drawn left of ${m.drawn[i - 1].tb}`)
}

const heights = {}
for (const [width, height] of [[1440, 900], [1280, 800], [390, 844]]) {
  await page.setViewportSize({ width, height })
  const wide = width >= 640
  for (const [view, suffix] of views) {
    await open(suffix)
    const m = await measure()
    const label = `${view} @${width}`
    heights[label] = `${Math.round(m.height)}px${m.folded ? ' (folded)' : ''}`
    const rows = !wide && PHONE_NAV.includes(view) ? 2 : 1
    const allowed = m.oneRow + (rows - 1) * (m.oneRow - 8)
    if (m.height > allowed) fail(`${label}: toolbar is ${m.height}px high, ${rows} row(s) is ${allowed}px`)
    checkOrder(label, m, wide)
    if (!wide && view !== 'board') {
      // The phone's Options drawer opens below the row and holds the view's controls.
      const toggle = page.locator('#tools-toggle')
      if (await toggle.count()) {
        await toggle.click()
        await page.waitForTimeout(150)
        const open = await page.evaluate(() => {
          const tools = document.querySelector('#swim-tools')
          const r = tools && tools.getBoundingClientRect()
          return { shown: !!r && r.height > 0, height: (document.querySelector('[phx-hook=ToolbarFold]') || document.querySelector('#view-menu').closest('.border-b')).getBoundingClientRect().height }
        })
        heights[`${label} drawer open`] = `${Math.round(open.height)}px`
        if (!open.shown) fail(`${label}: Options drawer shows nothing`)
        if (shots && view === 'timeline') await page.screenshot({ path: `${shots}/toolbar-${view}-${width}-drawer.png`, clip: { x: 0, y: 0, width, height: Math.min(height, open.height + 200) } })
        await toggle.click()
      } else fail(`${label}: no Options button on the phone`)
    }
    if (shots) await page.screenshot({ path: `${shots}/toolbar-${view}-${width}.png`, clip: { x: 0, y: 0, width, height: Math.min(height, Math.ceil(m.bottom) + 160) } })
  }
}
for (const [k, v] of Object.entries(heights)) console.log(`${k}: ${v}`)

// A folded control posts from the popover: the narrative's span, at 1280
// (and narrower if it happened to fit there).
async function foldedNarrative() {
  for (const [w, h] of [[1280, 800], [1024, 768], [800, 700]]) {
    await page.setViewportSize({ width: w, height: h })
    await open('/narrative')
    if ((await measure()).folded) return w
  }
  return null
}
const foldWidth = await foldedNarrative()
if (!foldWidth) fail('the narrative never folds its controls into View options, even at 800px')
else {
  const toggle = page.locator('#view-options-toggle')
  const span = page.locator('#swim-tools select[name=span]')
  if (await span.isVisible()) fail(`folded @${foldWidth}: the span select shows before View options is opened`)
  await toggle.click()
  if (!(await span.isVisible())) fail(`folded @${foldWidth}: View options did not show the span select`)
  else {
    if ((await toggle.getAttribute('aria-expanded')) !== 'true') fail('View options: aria-expanded is not true while open')
    const before = await span.inputValue()
    const other = await span.evaluate((s, cur) => [...s.options].map((o) => o.value).find((v) => v && v !== cur), before)
    await span.selectOption(other)
    await page.waitForFunction((v) => new URL(location.href).searchParams.get('span') === v, other, { timeout: 5000 }).catch(() => fail(`folded: choosing span ${other} in View options did not reach the URL (${page.url()})`))
    // Still open after the patch, and the choice stuck.
    if (!(await span.isVisible())) fail('folded: the popover closed when its select posted')
    if ((await span.inputValue()) !== other) fail(`folded: span reads ${await span.inputValue()} after the patch, want ${other}`)
    if (shots) await page.screenshot({ path: `${shots}/toolbar-narrative-${foldWidth}-view-options.png`, clip: { x: 0, y: 0, width: foldWidth, height: 420 } })
    // Escape closes it; the folded controls still post with the search box.
    await page.keyboard.press('Escape')
    await page.waitForTimeout(100)
    if (await span.isVisible()) fail('folded: Escape did not close View options')
    await page.locator('#swim-search input').fill('Task 1')
    await page.waitForFunction(() => new URL(location.href).searchParams.get('q') === 'Task 1', null, { timeout: 5000 }).catch(() => fail(`folded: search did not reach the URL (${page.url()})`))
    const url = new URL(page.url())
    if (url.searchParams.get('span') !== other) fail(`folded: searching dropped the folded span (${page.url()})`)
    // A button in the popover (the sort direction) posts too: a real browser
    // sends the button's own `value` with its phx-value-*, which LiveViewTest
    // never does.
    await toggle.click()
    const dir = page.locator('#view-options button[phx-value-key=dir]')
    if (!(await dir.isVisible())) fail('folded: the sort direction button is not in View options')
    else {
      const want = await dir.getAttribute('value')
      await dir.click()
      await page.waitForFunction((v) => new URL(location.href).searchParams.get('dir') === v, want, { timeout: 5000 }).catch(() => fail(`folded: the direction button in View options did not set dir=${want} (${page.url()})`))
      if (new URL(page.url()).searchParams.get('span') !== other) fail(`folded: the direction button dropped the folded span (${page.url()})`)
      const flipped = want === 'asc' ? 'desc' : 'asc'
      if ((await dir.getAttribute('value')) !== flipped) fail(`folded: the direction button reads ${await dir.getAttribute('value')} after its patch, want ${flipped}`)
      console.log(`folded @${foldWidth}: dir -> ${want} from the View options button`)
    }
    // A click outside closes it.
    if (!(await span.isVisible())) await toggle.click()
    await page.mouse.click(foldWidth / 2, 600)
    await page.waitForTimeout(100)
    if (await span.isVisible()) fail('folded: a click outside did not close View options')
    console.log(`folded @${foldWidth}: span ${before} -> ${other} from View options, kept through a search`)
  }
}

await browser.close()
if (problems.length) {
  console.log(problems.map((p) => `FAIL ${p}`).join('\n'))
  if (!process.env.MEASURE_ONLY) process.exit(1)
} else console.log('ok: one toolbar, one row, on every view')
