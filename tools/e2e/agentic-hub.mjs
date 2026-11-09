// The browser half of tools/e2e/agentic-hub.sh (#2012, #2600).
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
// Findings counts the proposals waiting on a person (#2123); the seed's two
// findings have none drafted, so they are its line.
const expect = { now: '1', runners: '1/2', findings: '0', ledger: '3', health: '1' }
const order = ['now', 'runners', 'findings', 'ledger', 'health']
for (const [key, n] of Object.entries(expect)) {
  const got = (await text(`#agentic-tile-${key} [data-role=tile-number]`)).trim()
  if (got !== n) fail(`${key} tile says ${got}, not ${n}`)
}
if ((await page.locator('#agentic-tile-health').getAttribute('data-attention')) !== 'warning') fail('Health is not ringed')
const nowLine = (await text('#agentic-tile-now [data-role=tile-line]')).trim()
if (nowLine !== '1 card in progress, 0 queued') fail(`Right now's line says ${nowLine}`)
const findingsLine = (await text('#agentic-tile-findings [data-role=tile-line]')).trim()
if (findingsLine !== 'Nothing waiting on you · 2 findings being handled') fail(`Findings' line says ${findingsLine}`)
const ids = await page.$$eval('#agentic-hub li > a', (els) => els.map((e) => e.id.replace('agentic-tile-', '')))
if (ids.join() !== order.join()) fail(`tiles in the order ${ids.join()}, not ${order.join()}`)

// The tiles' rows, top to bottom, each the tiles in it left to right.
const rows = () =>
  page.$$eval('#agentic-hub li', (els) => {
    const by = new Map()
    for (const e of els) {
      const b = e.getBoundingClientRect()
      const top = Math.round(b.top)
      by.set(top, [...(by.get(top) || []), { left: b.left, right: b.right, height: Math.round(b.height) }])
    }
    return [...by.entries()].sort((a, b) => a[0] - b[0]).map(([, r]) => r)
  })

// The five tiles share one row at 1440, each the same height, inside the page.
const wide = await rows()
if (wide.length !== 1 || wide[0].length !== 5) fail(`tiles at 1440 in rows of ${wide.map((r) => r.length).join(', ')}, not one of 5`)
if (new Set(wide[0].map((t) => t.height)).size !== 1) fail(`tiles at 1440 not one height: ${wide[0].map((t) => t.height).join(', ')}`)
if (Math.max(...wide[0].map((t) => t.right)) > 1440) fail('a tile runs off the page at 1440')
console.log(`ok: tiles ${Object.entries(expect).map(([k, n]) => `${k} ${n}`).join(', ')}, one row of 5, Health ringed`)

for (const t of ['light', 'dark']) {
  await theme(t)
  await page.waitForTimeout(200)
  await shot(`hub-${t}-1440`)
}
await theme('light')

// Each tile opens its place; Right now, Findings, Ledger and Health lead back.
for (const [key, url, ready] of [
  ['now', /\/now$/, '#now-title'],
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
console.log('ok: Right now, Findings, Ledger and Health open from their tiles and lead back')

await open(`/boards/${board}/agentic`)
await Promise.all([page.waitForURL(/\/automations$/), page.locator('#agentic-tile-runners').click()])
await page.waitForSelector('#board-runners')
for (const id of ['runners-findings', 'runners-ledger', 'runners-health'])
  if (await page.locator(`#${id}`).count()) fail(`the Runners header still has #${id}`)
console.log('ok: Runners opens Automations, its header without the three old buttons')

// Phone: two tiles a row (2, 2, then Health alone), nothing wider than the screen.
await page.setViewportSize({ width: 390, height: 844 })
await open(`/boards/${board}/agentic`)
for (const t of ['light', 'dark']) {
  await theme(t)
  await page.waitForTimeout(200)
  const phone = await rows()
  const shape = phone.map((r) => r.length).join(', ')
  if (shape !== '2, 2, 1') fail(`${t}: tiles at 390 in rows of ${shape}, not 2, 2, 1`)
  const scroll = await page.evaluate(() => document.documentElement.scrollWidth)
  if (scroll > 390) fail(`${t}: ${scroll}px wide`)
  await shot(`hub-${t}-390`)
}
await open(`/boards/${board}/health`)
await shot('health-back-light-390')
console.log('ok: two tiles a row at 390, nothing wider than the phone')

await browser.close()
console.log('ok')
