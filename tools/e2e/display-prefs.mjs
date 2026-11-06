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

await browser.close()
if (problems.length) {
  console.log(problems.map((p) => `FAIL ${p}`).join('\n'))
  process.exit(1)
} else console.log('ok: display options are remembered in this browser only')
