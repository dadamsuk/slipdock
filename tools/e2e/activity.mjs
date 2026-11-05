// The browser half of tools/e2e/activity.sh (#1735), as a reader in
// Auckland: Today's and Yesterday's entries either side of their midnight,
// every entry naming its actor, and the oldest entries loading only once
// the list is scrolled to its end.
//
//   node tools/e2e/activity.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const fail = (w) => { throw new Error(w) }
const shots = process.env.SHOTS
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, timezoneId: 'Pacific/Auckland' })
const page = await context.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

await page.goto(`${base}/boards/${board}/activity`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
await page.waitForSelector('#activity-days')

const days = await page.$$eval('[data-role=activity-day]', (els) =>
  els.map((s) => ({ label: s.querySelector('h3').textContent.trim(), text: s.textContent.replace(/\s+/g, ' ') })))
const labels = days.map((d) => d.label)
if (labels[0] !== 'Today' || labels[1] !== 'Yesterday') fail(`day headings are ${labels.join(', ')}`)
const today = days[0].text, yesterday = days[1].text
for (const want of ['Erin Example edited', 'claude wrote', 'Automation: Triage commented'])
  if (!today.includes(want)) fail(`Today lacks "${want}": ${today}`)
for (const want of ['Gale Gone voted', 'Email from Erin Example added'])
  if (!yesterday.includes(want)) fail(`Yesterday lacks "${want}": ${yesterday}`)

const blank = await page.$$eval('[data-role=activity-actor]', (els) => els.filter((e) => !e.textContent.trim()).length)
if (blank) fail(`${blank} entries name nobody`)
const avatars = await page.$$eval('#activity-days li[data-actor-kind=person] .avatar-initials', (els) => els.map((e) => e.textContent.trim()))
if (!avatars.includes('EE') || !avatars.includes('GG')) fail(`person avatars are ${avatars}`)
if (shots) await page.screenshot({ path: `${shots}/activity-top.png` })

const count = () => page.$$eval('#activity-days li', (els) => els.length)
const before = await count()
if (before !== 50) fail(`first page has ${before} entries, not 50`)
// Scroll the list to its end: the rest arrive without a click.
for (let i = 0; i < 10 && (await count()) === before; i++) {
  await page.$eval('#activity-scroll', (el) => { el.scrollTop = el.scrollHeight })
  await page.waitForTimeout(400)
}
const after = await count()
// 61 seeded, plus the harness's own lines (the board, its page).
if (after < 61) fail(`after scrolling there are ${after} entries, not 61 or more`)
if (await page.locator('#activity-more').count()) fail('Load more is still there with nothing left')
const someone = await page.$$eval('[data-actor-kind=unknown] [data-role=activity-actor]', (els) => els.map((e) => e.textContent.trim()))
if (!someone.includes('Someone')) fail('the row with no actor does not read Someone')
if (shots) await page.screenshot({ path: `${shots}/activity-bottom.png` })

console.log(`ok: ${labels.slice(0, 3).join(' / ')}…; ${before} then ${after} entries`)
await browser.close()
