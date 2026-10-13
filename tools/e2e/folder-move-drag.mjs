// The browser half of tools/e2e/folder-move-drag.sh (#746).
//
//   node tools/e2e/folder-move-drag.mjs <login-url> <base-url> <kb-id> <hunt-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, hunt] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  // The link opens a page asking to confirm the sign-in; a scanner that
  // follows links never gets past it.
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  // The vault's own view, whose tree is the vault's (#752), organising.
  await page.goto(`${base}/vaults/GMinds`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('[data-key="board:' + hunt + '"]')
  await page.click("button[phx-click='toggle_organise']")

  const specs = page.locator('.wt-row', { hasText: 'Specs' }).first()
  await specs.waitFor()
  const handle = specs.locator('[data-drag]')
  await handle.waitFor()
  const target = page.locator(`[data-key="board:${hunt}"]`).first()

  const from = await handle.boundingBox()
  const to = await target.boundingBox()
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2)
  await page.mouse.down()
  // In steps, as a hand would: the tree starts a drag after a few pixels.
  for (let i = 1; i <= 12; i++) {
    await page.mouse.move(from.x + 4, from.y + (to.y + to.height / 2 - from.y) * (i / 12))
  }
  await page.mouse.move(to.x + to.width / 3, to.y + to.height / 2)
  await page.mouse.up()

  const dialog = page.locator('#tree-prompt')
  await dialog.getByText('Move the folder “Specs” to Job Hunt?').waitFor({ timeout: 5000 })
  const summary = await page.locator('#cross-move-folders').innerText()
  if (!/1 folder, 1 page/.test(summary)) fail('the confirmation said: ' + summary)

  await page.click('#cross-move-confirm')
  await page.getByText('Moved 1 folder to Job Hunt.').waitFor({ timeout: 5000 })
  console.log('ok: dragged, confirmed, moved')
} catch (e) {
  await page.screenshot({ path: '/tmp/folder-move-drag-failure.png' })
  fail(e.message + ' (screenshot: /tmp/folder-move-drag-failure.png)')
} finally {
  await browser.close()
}
