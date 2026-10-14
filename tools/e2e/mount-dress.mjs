// The browser half of tools/e2e/mount-dress.sh (#797): the mounted board's
// row has a ⋯ menu where its count would otherwise sit, and dressing it
// from there shows on the row.
//
//   node tools/e2e/mount-dress.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

// The mount's row: a ⋯ button, and its count left of it, not in its place.
async function checkRow(where) {
  const row = page.locator('.wt-row', { hasText: 'Plans' }).first()
  await row.waitFor()
  await row.hover()
  const button = row.locator('[data-menu]')
  if (!(await button.count())) fail(`${where}: the Plans row has no ⋯ button`)
  const rowBox = await row.boundingBox()
  const buttonBox = await button.boundingBox()
  if (buttonBox.x + buttonBox.width < rowBox.x + rowBox.width - 12) fail(`${where}: the ⋯ button isn't at the row's end`)
  await button.click()
  const item = page.locator('[data-menu-item]', { hasText: 'Icon and colour' }).first()
  await item.waitFor({ timeout: 3000 }).catch(() => fail(`${where}: no Icon and colour… in the menu`))
  return item
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // The vault's view first, then the board mounted at its top.
  await page.goto(`${base}/vaults/Notes`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await checkRow('vault view')
  await page.keyboard.press('Escape')
  console.log('ok: the vault view has the menu')

  await page.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const item = await checkRow('board wiki')
  await item.click()
  await page.locator('#mount-modal #mount-form').waitFor()
  await page.locator('#mount-dress label:has(input[name=icon][value=briefcase])').click()
  await page.locator('#mount-form button[type=submit]').click()
  await page.locator('#mount-modal #mount-form').waitFor({ state: 'detached' })
  await page.locator('.wt-row', { hasText: 'Plans' }).first().locator('.hero-briefcase').waitFor({ timeout: 5000 })
  console.log('ok: the board wiki has the menu, and the mount wears its icon')
} catch (e) {
  await page.screenshot({ path: '/tmp/mount-dress-failure.png' })
  fail(e.message + ' (screenshot: /tmp/mount-dress-failure.png)')
} finally {
  await browser.close()
}
