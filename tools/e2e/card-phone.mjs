// The browser half of tools/e2e/card-phone.sh (#1729).
//
//   node tools/e2e/card-phone.mjs <login-url> <base-url> <board-id> <card-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const ok = (what) => console.log('ok: ' + what)

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })
const page = await context.newPage()
const settle = () => page.waitForTimeout(600)

const open = async () => {
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-title-form')
  await settle()
}
const onFirstScreen = async (sel, what) => {
  const el = page.locator(sel).first()
  if (!(await el.count())) fail(`${what}: nothing at ${sel}`)
  const b = await el.boundingBox()
  if (!b || !(await el.isVisible())) fail(`${what} is not visible`)
  if (b.y < 0 || b.y + b.height > 844) fail(`${what} is off the first screen (y ${Math.round(b.y)}–${Math.round(b.y + b.height)})`)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await open()
  if (shots) await page.screenshot({ path: `${shots}/phone-first-screen.png` })

  // The first screen: list, assignee, due date and priority.
  await onFirstScreen('#card-meta select[name="card[column_id]"]', 'the list')
  await onFirstScreen('#card-phone-summary [data-summary=assignee]', 'the assignee')
  await onFirstScreen('#card-phone-summary [data-summary=due]', 'the due date')
  await onFirstScreen('#card-phone-summary [data-summary=priority]', 'the priority')
  const text = (await page.locator('#card-phone-summary').innerText()).replace(/\s+/g, ' ')
  if (!/e2e@example\.com/.test(text) || !/Due /.test(text) || !/High/.test(text)) fail(`the summary reads "${text}"`)
  ok(`at 390px the first screen has the list and "${text.trim()}"`)

  // The description is after the properties, not before them.
  const desc = await page.locator('[data-section-key=d]').boundingBox()
  const summary = await page.locator('#card-phone-summary').boundingBox()
  if (desc.y < summary.y) fail('the description comes before the properties')
  ok('the long sections follow the properties')

  // Tapping the summary opens the rows; a change saves, and they stay open.
  await page.tap('#card-phone-summary')
  await page.waitForSelector('#card-phone-props #card-priority', { state: 'visible' })
  if (shots) await page.screenshot({ path: `${shots}/phone-props-open.png` })
  await page.locator('#card-phone-props #card-priority').selectOption('low')
  await settle()
  if (!(await page.locator('#card-phone-props').isVisible())) fail('the rows closed on a save')
  const summaryNow = (await page.locator('#card-phone-summary [data-summary=priority]').innerText()).trim()
  if (summaryNow !== 'Low') fail(`the summary says "${summaryNow}" after picking Low`)
  ok('tapping opens the rows; picking Low saves it and the summary follows, still open')

  await open()
  if ((await page.locator('#card-phone-summary [data-summary=priority]').innerText()).trim() !== 'Low') fail('Low did not save')
  if (await page.locator('aside #card-props').count()) fail('the sidebar draws the properties as well on a phone')
  ok('it saved; the sidebar does not draw them twice')

  // A desktop is as it was: the properties in the sidebar, no summary.
  await page.setViewportSize({ width: 1280, height: 900 })
  await open()
  if (await page.locator('#card-phone-summary').count()) fail('a desktop shows the phone summary')
  if (!(await page.locator('aside #card-props #card-priority').isVisible())) fail('a desktop has no properties in the sidebar')
  ok('a desktop keeps the properties in the sidebar, with no summary')
} finally {
  await browser.close()
}
