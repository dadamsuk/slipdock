// The browser half of tools/e2e/display-prefs.sh (#1879).
//
//   node tools/e2e/display-prefs.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const problems = []
const fail = (w) => problems.push(w)
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })

async function signIn(context) {
  const page = await context.newPage({ viewport: { width: 1280, height: 800 } })
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  return page
}

async function openBoard(page) {
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  // Give the hook its round trip: push, restore, patch.
  await page.waitForTimeout(800)
}

async function choose(page, density) {
  await page.locator('#display-menu [role=button]').click()
  await page.locator(`#display-menu input[name=density][value=${density}] + span`).click()
  await page.waitForTimeout(500)
}

const query = (page) => new URL(page.url()).search

const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } })
const page = await signIn(ctx)
await openBoard(page)
if (query(page) !== '') fail(`first visit: URL has ${query(page)}, want none`)

await choose(page, 'compact')
if (!/density=compact/.test(query(page))) fail(`after choosing compact: URL has "${query(page)}"`)

// Away and back to the bare address.
await page.goto(`${base}/wiki`, { waitUntil: 'load' })
await openBoard(page)
if (!/density=compact/.test(query(page))) fail(`back on the board: URL has "${query(page)}", want density=compact`)
if (!(await page.locator('#display-menu input[name=density][value=compact]').isChecked()))
  fail('back on the board: Compact is not the chosen card size')
if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/display-prefs-restored.png` })

// Back does not land on the bare URL: the restore replaced it.
const remembered = await page.evaluate((b) => localStorage.getItem(`slipdock:display:${b}:board`), board)
if (!/compact/.test(remembered || '')) fail(`localStorage holds ${remembered}`)

// Another browser (a fresh context, its own storage) starts from the defaults.
const ctx2 = await browser.newContext({ viewport: { width: 1280, height: 800 } })
const other = await ctx2.newPage()
await other.context().addCookies(await ctx.cookies())
await openBoard(other)
if (query(other) !== '') fail(`another browser: URL has "${query(other)}", want none`)

// Going back to comfortable is remembered too.
await choose(page, 'normal')
await page.goto(`${base}/wiki`, { waitUntil: 'load' })
await openBoard(page)
if (query(page) !== '') fail(`after the reset: URL has "${query(page)}", want none`)

// On a phone (#1926): the Display menu and the View menu open wholly on
// screen. A button mid-toolbar has room on neither side for a 288px menu, and
// end-aligning alone put the Display menu's left edge at -66px.
const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
await phone.addCookies(await ctx.cookies())
const p = await phone.newPage()
await openBoard(p)
const onScreen = async (menu, when) => {
  const r = await p.evaluate((m) => {
    const b = document.querySelector(`#${m} .dropdown-content`).getBoundingClientRect()
    return { left: Math.round(b.left), right: Math.round(b.right), vw: document.documentElement.clientWidth }
  }, menu)
  if (r.left < 8 || r.right > r.vw - 8) fail(`phone, ${menu} ${when}: menu at ${r.left}–${r.right} on a ${r.vw}px screen`)
  return r
}
await p.locator('#display-menu [role=button]').click()
await p.waitForTimeout(300)
const shown = await onScreen('display-menu', 'opened')
if (process.env.SHOTS) await p.screenshot({ path: `${process.env.SHOTS}/display-menu-phone.png` })
// Choosing an option patches the menu; it must stay where it is.
await p.locator('#display-menu input[name=density][value=compact] + span').click()
await p.waitForTimeout(500)
await onScreen('display-menu', 'after choosing compact')
await p.locator('body').click({ position: { x: 5, y: 600 } })
await p.locator('#view-menu [role=button]').click()
await p.waitForTimeout(300)
await onScreen('view-menu', 'opened')
await phone.close()

await browser.close()
if (problems.length) {
  console.log(problems.map((p) => `FAIL ${p}`).join('\n'))
  process.exit(1)
} else console.log(`ok: display options are remembered in this browser only; on a phone the Display menu opens at ${shown.left}–${shown.right} of ${shown.vw}px`)
