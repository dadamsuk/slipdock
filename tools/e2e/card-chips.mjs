// The browser half of tools/e2e/card-chips.sh (#1708). On a board with no
// saved Display settings: only the essential facets show; neutral chips in
// the card's meta row have no outline, no fill and no side padding; the
// states that need attention keep a fill; medium priority is off the face;
// and with start and due both shown, one range chip replaces the two.
//
//   node tools/e2e/card-chips.mjs <login-url> <base-url> <board> <full> <late> <soon> <blocked> <waiting>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, full, late, soon, blocked, waiting] = process.argv.slice(2)
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
// The computed look of the first match, or null when there is none.
const look = async (page, sel) => {
  const loc = page.locator(sel).first()
  if (!(await loc.count())) return null
  return loc.evaluate((el) => {
    const s = getComputedStyle(el)
    return { shadow: s.boxShadow, bg: s.backgroundColor, padLeft: parseFloat(s.paddingLeft), text: el.textContent.trim() }
  })
}
const clear = (c) => c === 'rgba(0, 0, 0, 0)' || c === 'transparent'
const has = async (page, sel) => (await page.locator(sel).count()) > 0
const shoot = async (page, name) => {
  if (shots) await page.locator('#board-scroll').first().screenshot({ path: `${shots}/card-chips-${name}.png` })
}

const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await ctx.newPage()
await signIn(page)

// The defaults.
await open(page, `/boards/${board}`)
await shoot(page, 'board')
if (shots) await page.locator(`#card-${full}`).screenshot({ path: `${shots}/card-chips-full.png` })
const f = `#card-${full}`
check(await has(page, `${f} [title^='Priority']`), 'high priority missing from the face')
check(await has(page, `${f} [title^='Due']`), 'due date missing from the face')
check(await has(page, `${f} [title='Checklist']`), 'checklist missing from the face')
for (const [what, sel] of [
  ['start date', "[title^='Starts']"], ['description mark', "[title='Has description']"],
  ['comments', "[title='Comments']"], ['% complete', "[title='40% complete']"],
  ['time in list', '[data-role=age-chip]'],
]) check(!(await has(page, `${f} ${sel}`)), `${what} shown by default`)
check(!(await has(page, `#card-${late} [title^='Priority']`)), 'medium priority shown on the face')

// Neutral: no outline, no fill, no side padding.
for (const [what, sel] of [['later due date', `${f} [title^='Due']`], ['checklist', `${f} [title='Checklist']`]]) {
  const l = await look(page, sel)
  check(l && l.shadow === 'none', `${what}: outline ${l && l.shadow}`)
  check(l && clear(l.bg), `${what}: fill ${l && l.bg}`)
  check(l && l.padLeft === 0, `${what}: padding ${l && l.padLeft}px`)
}

// Needing attention: a fill.
for (const [what, sel] of [
  ['overdue', `#card-${late} [title^='Due']`],
  ['due soon', `#card-${soon} [title^='Due']`],
  ['flagged', `#card-${soon} [title='Flagged']`],
  ['blocked', `#card-${blocked} [title^='Blocked by']`],
  ['waiting', `#card-${waiting} [data-role=wait-mark]`],
]) {
  const l = await look(page, sel)
  check(l && !clear(l.bg), `${what}: no fill (${l ? l.bg : 'missing'})`)
}

// Start and due as one range.
await open(page, `/boards/${board}?show=tags,priority,start_date,due_date`)
const range = await look(page, `${f} [data-role=date-range]`)
check(range && range.text.includes('→'), `range: ${range ? range.text : 'missing'}`)
check(!(await has(page, `${f} [title^='Due']`)), 'a separate due chip beside the range')
if (shots) await page.locator(f).screenshot({ path: `${shots}/card-chips-range.png` })

// Compact cards: the same defaults.
await open(page, `/boards/${board}?density=compact`)
check(!(await has(page, `${f} [title='Comments']`)), 'compact: comments shown by default')
check(await has(page, `${f} [title^='Due']`), 'compact: due date missing')
await shoot(page, 'compact')

await browser.close()
if (failures.length) { console.error('FAIL:\n- ' + failures.join('\n- ')); process.exit(1) }
console.log('ok: essentials only by default (comfortable and compact); neutral chips plain; attention tinted; medium off; start-due range')
