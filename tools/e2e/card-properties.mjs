// The browser half of tools/e2e/card-properties.sh (#1726).
//
//   node tools/e2e/card-properties.mjs <login-url> <base-url> <board-id> <card-id> <second-list-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, secondList, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const ok = (what) => console.log('ok: ' + what)

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 1000 } })).newPage()

const open = async () => {
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-title-form')
}
const settle = () => page.waitForTimeout(700)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await open()
  if (shots) await page.locator('aside').first().screenshot({ path: `${shots}/sidebar.png` })

  // Label on the left, value on the right, one row each.
  const rows = page.locator('#card-props [data-prop]')
  const n = await rows.count()
  if (n < 6) fail(`${n} property rows, want at least 6`)
  for (let i = 0; i < n; i++) {
    const row = rows.nth(i)
    if (!(await row.isVisible())) continue
    const name = await row.getAttribute('data-prop')
    const label = await row.locator('[data-role=prop-label]').boundingBox()
    const value = await row.locator('[data-role=prop-value]').boundingBox()
    if (!label || !value) fail(`${name}: no label or value`)
    if (label.x + label.width > value.x + 1) fail(`${name}: the label is not left of the value`)
    if (label.y > value.y + value.height || value.y > label.y + label.height) fail(`${name}: label and value are not on one row`)
  }
  ok(`${n} properties, each a label left of its value`)

  // No duplicates: List and Completed are the meta line's and the title's.
  if (await page.locator('aside select[name="card[column_id]"]').count()) fail('the sidebar still has a List select')
  if (await page.locator('aside input[name="card[completed]"]').count()) fail('the sidebar still has a Completed switch')
  ok('no List select or Completed switch in the sidebar')

  // Bare until you reach for it: no visible border on a value at rest.
  const sel = page.locator('#card-props select[name="card[priority]"]')
  const border = await sel.evaluate((el) => getComputedStyle(el).borderTopColor)
  if (!/rgba\(.*, 0\)$|transparent/.test(border)) fail(`the priority select has a border at rest (${border})`)
  ok('values are bare at rest')

  // Priority saves.
  await sel.selectOption('low')
  await settle()
  await open()
  if ((await page.locator('#card-props select[name="card[priority]"]').inputValue()) !== 'low') fail('priority did not save')
  ok('priority saves')

  // Precision: hidden at "day" until More is opened.
  const precision = page.locator('#card-precision')
  if (await precision.isVisible()) fail('Precision shows at "day" without More')
  await page.click('#card-props-more-toggle')
  await precision.waitFor({ state: 'visible' })
  ok('More shows Precision')
  if (shots) await page.locator('aside').first().screenshot({ path: `${shots}/sidebar-more.png` })
  await precision.selectOption('week')
  await settle()
  await open()
  if (!(await page.locator('#card-precision').isVisible())) fail('Precision is hidden once it is not "day"')
  if (await page.locator('#card-props-more #card-precision').count()) fail('a week precision is still inside More')
  ok('a precision other than day is its own row')

  // The meta line's list and the title's check still work.
  await page.locator('#card-meta select[name="card[column_id]"]').selectOption(secondList)
  await settle()
  await page.click('#card-title-form button[phx-click=toggle_complete]')
  await settle()
  await open()
  if ((await page.locator('#card-meta select[name="card[column_id]"]').inputValue()) !== secondList) fail('the meta line list did not move the card')
  const title = await page.locator('#card-title-form button[phx-click=toggle_complete]').getAttribute('title')
  if (title !== 'Mark incomplete') fail(`the title check did not complete the card (${title})`)
  ok('the meta line moves the card and the title check completes it')
} finally {
  await browser.close()
}
