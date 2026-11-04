// The browser half of tools/e2e/card-title.sh (#1707). On the board, the
// swimlanes and a sub-board: the comfortable title is 13px or larger and its
// left edge is the tag row's, before and after a hover; hovering or focusing
// shows the complete toggle without moving the title; a compact title is
// 12px; on a touch phone the toggle is visible and the title still flush;
// and the toggle completes the card.
//
//   node tools/e2e/card-title.mjs <login-url> <base-url> <board> <card> <sub-board> <child>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, card, sub, child] = process.argv.slice(2)
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
// Where a card's title, tag row and toggle are, and how big the title is.
const measure = async (page, sel) => page.locator(sel).first().evaluate((el) => {
  // (The fallbacks find the title and toggle on the face before #1707.)
  const title = el.querySelector('[data-role=card-title]') || el.querySelector('p.font-medium')
  const tag = title.closest('.space-y-2')?.firstElementChild
  const toggle = el.querySelector('[data-role=complete-toggle]') || el.querySelector('button[title^=Mark]')
  return {
    titleX: title.getBoundingClientRect().left,
    tagX: tag && tag !== title.parentElement ? tag.getBoundingClientRect().left : null,
    size: parseFloat(getComputedStyle(title).fontSize),
    toggle: toggle ? parseFloat(getComputedStyle(toggle).opacity) : null,
  }
})
const near = (a, b) => a !== null && b !== null && Math.abs(a - b) <= 0.5

const desktop = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await desktop.newPage()
await signIn(page)
const surfaces = [
  ['board', `/boards/${board}`, `#card-${card}`],
  ['swimlanes', `/boards/${board}/swimlanes`, `[id^=swim-][id$="-card-${card}"]`],
  ['sub-board', `/boards/${sub}`, `#card-${child}`],
]
for (const [name, path, sel] of surfaces) {
  await open(page, path)
  await page.mouse.move(0, 0)
  const rest = await measure(page, sel)
  check(rest.size >= 13, `${name}: title is ${rest.size}px`)
  check(near(rest.titleX, rest.tagX), `${name}: title at x=${rest.titleX}, tags at x=${rest.tagX}`)
  check(rest.toggle === 0, `${name}: toggle opacity ${rest.toggle} at rest`)
  await page.locator(sel).first().hover()
  await page.waitForTimeout(250)
  const hover = await measure(page, sel)
  check(hover.toggle === 1, `${name}: toggle opacity ${hover.toggle} on hover`)
  check(near(hover.titleX, rest.titleX), `${name}: hover moved the title ${rest.titleX} → ${hover.titleX}`)
  if (shots) await page.locator(sel).first().screenshot({ path: `${shots}/card-title-${name}.png` })
}

// Keyboard: focusing the card shows its toggle.
await open(page, `/boards/${board}`)
await page.mouse.move(0, 0)
await page.locator(`#card-${card}`).focus()
await page.waitForTimeout(250)
check((await measure(page, `#card-${card}`)).toggle === 1, 'toggle hidden while the card has focus')

// Compact cards.
await open(page, `/boards/${board}?density=compact`)
const compact = await measure(page, `#card-${card}`)
check(compact.size === 12, `compact title is ${compact.size}px`)

// The toggle works: hover, click, the card is done.
await open(page, `/boards/${board}`)
await page.locator(`#card-${card}`).hover()
await page.locator(`#card-${card} [data-role=complete-toggle]`).click()
await page.waitForSelector(`#card-${card} [aria-label="Mark incomplete"]`, { timeout: 5000 }).catch(() => failures.push('clicking the toggle did not complete the card'))
await page.locator(`#card-${card} [data-role=complete-toggle]`).click()
await page.waitForSelector(`#card-${card} [aria-label="Mark complete"]`, { timeout: 5000 }).catch(() => failures.push('clicking again did not reopen the card'))

// A phone: no hover, so the toggle is always there, and the title still flush.
// The sign-in link is single-use, so the phone carries the desktop's session.
const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, storageState: await desktop.storageState() })
const mpage = await phone.newPage()
await open(mpage, `/boards/${sub}`)
const m = await measure(mpage, `#card-${child}`)
check(m.toggle === 1, `phone: toggle opacity ${m.toggle}`)
check(near(m.titleX, m.tagX), `phone: title at x=${m.titleX}, tags at x=${m.tagX}`)
check(m.size >= 13, `phone: title is ${m.size}px`)
if (shots) await mpage.locator(`#card-${child}`).screenshot({ path: `${shots}/card-title-phone.png` })

await browser.close()
if (failures.length) { console.error('FAIL:\n- ' + failures.join('\n- ')); process.exit(1) }
console.log('ok: titles flush and 13px+ on board, swimlanes, sub-board and phone; compact 12px; toggle on hover, focus, touch')
