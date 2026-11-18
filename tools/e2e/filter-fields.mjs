// The browser half of tools/e2e/filter-fields.sh (#3369).
//
//   node tools/e2e/filter-fields.mjs <login-url> <base-url> <board-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 1000 } })).newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }

const titles = ['Tiny fix', 'Big rebuild', 'Unsized idea']
const shown = async () => {
  const text = await page.locator('main').innerText()
  return titles.filter((t) => text.includes(t))
}
const expectShown = async (want, step) => {
  for (let i = 0; i < 30; i++) {
    const got = await shown()
    if (JSON.stringify(got) === JSON.stringify(want)) return
    await page.waitForTimeout(100)
  }
  fail(`${step}: expected ${JSON.stringify(want)}, saw ${JSON.stringify(await shown())}`)
}
const openMenu = async () => {
  const menu = page.locator('[data-role="filter-fields"]')
  if (!(await menu.isVisible())) await page.locator('[role=button][title="Filter"]').first().click()
  await menu.waitFor({ state: 'visible' })
  return menu
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await expectShown(titles, 'unfiltered')

  // A choice: pick Large.
  let menu = await openMenu()
  await shot('1-menu')
  await menu.locator('[data-field-filter="size"] button', { hasText: 'Large' }).click()
  await expectShown(['Big rebuild'], 'Size = Large')

  // Picking it again drops the filter.
  menu = await openMenu()
  await menu.locator('[data-field-filter="size"] button', { hasText: 'Large' }).click()
  await expectShown(titles, 'Size cleared')

  // A number range: at most 5.
  menu = await openMenu()
  await menu.locator('form[data-field-filter="effort"] input[name="max"]').fill('5')
  await expectShown(['Tiny fix'], 'Effort <= 5')
  await menu.locator('form[data-field-filter="effort"] input[name="max"]').fill('')
  await expectShown(titles, 'Effort cleared')

  // A date, through the app's date field: from 2027-01-01.
  menu = await openMenu()
  const from = menu.locator('form[data-field-filter="launch"] input[name="from"]')
  await from.evaluate((el) => {
    el.value = '2027-01-01'
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
  })
  await expectShown(['Big rebuild'], 'Launch from 2027-01-01')
  await shot('2-date')

  const badge = await page.locator('[role=button][title="Filter"] .badge').first().innerText()
  if (badge.trim() !== '1') fail(`badge shows ${badge}, expected 1`)

  menu = await openMenu()
  await menu.page().locator('button', { hasText: 'Clear all filters' }).first().click()
  await expectShown(titles, 'Clear all filters')

  console.log('ok')
} catch (e) {
  fail(e.message)
} finally {
  await browser.close()
}
