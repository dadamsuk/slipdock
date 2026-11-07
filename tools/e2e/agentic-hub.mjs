// The browser half of tools/e2e/agentic-hub.sh (#2012).
//
//   node tools/e2e/agentic-hub.mjs <login-url> <base-url> <board-id>
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
const text = (sel) => page.locator(sel).first().innerText()

await open(`/boards/${board}/agentic`)
const expect = { runners: '1/2', findings: '2', ledger: '3', health: '1' }
for (const [key, n] of Object.entries(expect)) {
  const got = (await text(`#agentic-tile-${key} [data-role=tile-number]`)).trim()
  if (got !== n) fail(`${key} tile says ${got}, not ${n}`)
}
if ((await page.locator('#agentic-tile-health').getAttribute('data-attention')) !== 'warning') fail('Health is not ringed')

// The four tiles share one row at 1440, each the same height.
const boxes = await page.$$eval('#agentic-hub li', (els) => els.map((e) => e.getBoundingClientRect()))
if (boxes.length !== 4 || new Set(boxes.map((b) => Math.round(b.top))).size !== 1) fail(`tiles not one row: ${JSON.stringify(boxes.map((b) => b.top))}`)
console.log(`ok: tiles ${Object.entries(expect).map(([k, n]) => `${k} ${n}`).join(', ')}, one row, Health ringed`)

for (const t of ['light', 'dark']) {
  await theme(t)
  await page.waitForTimeout(200)
  await shot(`hub-${t}-1440`)
}
await theme('light')

// Each tile opens its place; Findings, Ledger and Health lead back.
for (const [key, url, ready] of [
  ['findings', /\/findings$/, '#findings-title'],
  ['ledger', /\/ledger$/, '#ledger-title'],
  ['health', /\/health$/, '#health-shell, h1'],
]) {
  await open(`/boards/${board}/agentic`)
  await Promise.all([page.waitForURL(url), page.locator(`#agentic-tile-${key}`).click()])
  await page.waitForSelector(ready)
  await page.waitForSelector('#agentic-back')
  if (key === 'findings') await shot(`findings-back-light-1440`)
  await Promise.all([page.waitForURL(/\/agentic$/), page.locator('#agentic-back').click()])
  await page.waitForSelector('#agentic-hub')
}
console.log('ok: Findings, Ledger and Health open from their tiles and lead back')

await open(`/boards/${board}/agentic`)
await Promise.all([page.waitForURL(/\/automations$/), page.locator('#agentic-tile-runners').click()])
await page.waitForSelector('#board-runners')
for (const id of ['runners-findings', 'runners-ledger', 'runners-health'])
  if (await page.locator(`#${id}`).count()) fail(`the Runners header still has #${id}`)
console.log('ok: Runners opens Automations, its header without the three old buttons')

// Phone: two tiles a row, nothing wider than the screen.
await page.setViewportSize({ width: 390, height: 844 })
await open(`/boards/${board}/agentic`)
for (const t of ['light', 'dark']) {
  await theme(t)
  await page.waitForTimeout(200)
  const tops = await page.$$eval('#agentic-hub li', (els) => els.map((e) => Math.round(e.getBoundingClientRect().top)))
  if (new Set(tops).size !== 2) fail(`${t}: tiles on ${new Set(tops).size} rows at 390`)
  const wide = await page.evaluate(() => document.documentElement.scrollWidth)
  if (wide > 390) fail(`${t}: ${wide}px wide`)
  await shot(`hub-${t}-390`)
}
await open(`/boards/${board}/health`)
await shot('health-back-light-390')
console.log('ok: two tiles a row at 390, nothing wider than the phone')

await browser.close()
console.log('ok')
