// The browser half of tools/e2e/tidy.sh (W-1807, #1084).
//
//   node tools/e2e/tidy.mjs <login-url> <base-url> <board-id> <doing> <a> <b>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, doing, a, b] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1600, height: 900 } })).newPage()

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

const has = (sel, text) => page.locator(sel, text ? { hasText: text } : {}).count().then(n => n > 0)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // The board's menu leads to the page.
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const link = page.locator(`a[href="/boards/${board}/tidy"]`).first()
  if (!(await link.count())) fail('no Tidy up… in the board menu')
  await page.goto(`${base}/boards/${board}/tidy`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await until('no empty state', () => has('#garden-empty'))

  await page.click('#garden-run')
  await until('nothing found', () => has('#garden-completed_not_done', 'Finished thing'))
  await until('the stuck card was not found', () => has('#garden-stale_in_progress', 'Stuck thing'))
  console.log('ok: Look the board over found both')

  // Apply the first; then an alternative on the second.
  await page.locator('#garden-completed_not_done li', { hasText: 'Finished thing' }).getByRole('button', { name: 'Apply', exact: true }).click()
  await until('applied suggestion still open', async () => !(await has('#garden-completed_not_done')))
  await until('not under Recently applied', () => has('#garden-applied', 'Finished thing'))
  console.log('ok: Apply')

  await page.locator('#garden-stale_in_progress li', { hasText: 'Stuck thing' }).getByRole('button', { name: 'Snooze', exact: true }).click()
  await until('snoozed suggestion still open', async () => !(await has('#garden-stale_in_progress')))
  if (!(await has('#garden-applied', 'Finished thing'))) fail('the first applied suggestion went missing')
  console.log('ok: Snooze, and the first stays applied')

  // Undo the first.
  await page.locator('#garden-applied li', { hasText: 'Finished thing' }).getByRole('button', { name: 'Undo' }).click()
  await until('undone suggestion not back', () => has('#garden-completed_not_done', 'Finished thing'))
  console.log('ok: Undo')
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
