// The browser half of tools/e2e/page-details.sh.
//
//   node tools/e2e/page-details.mjs <login-url> <base-url> <kb-id> <page-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, pageId] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })
const connected = () => page.waitForSelector('.phx-connected')
const toggle = `#page-details-toggle-${pageId}`
const panel = `#page-details-${pageId}`
const top = async (sel) => (await page.locator(sel).first().boundingBox()).y

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${kb}/wiki/acme-call`, { waitUntil: 'networkidle' })
  await connected()

  if (await page.isVisible(panel)) fail('the details should start closed')
  if ((await top('#page-actions')) >= (await top('article h1'))) fail('actions should sit above the title')
  console.log('ok: the actions sit above the title, details closed')

  await page.click(toggle)
  await page.waitForSelector(panel, { state: 'visible' })
  if ((await page.getAttribute(toggle, 'aria-expanded')) !== 'true') fail('aria-expanded not set')
  const actionsBox = await page.locator('#page-actions').boundingBox()
  const panelBox = await page.locator(panel).boundingBox()
  if (panelBox.y < actionsBox.y + actionsBox.height - 1) fail('the details should open beneath the row')
  if (panelBox.y >= (await top('article h1'))) fail('the details should open above the title')
  console.log('ok: Page details opens just beneath the action row')

  // A server update (the heart) must not close it.
  await page.click('#page-actions button[phx-click=toggle_favourite]')
  await page.waitForTimeout(700)
  if (!(await page.isVisible(panel))) fail('the details closed on a page update')
  console.log('ok: still open after a favourite')

  await page.click(toggle)
  await page.waitForSelector(panel, { state: 'hidden' })
  if ((await page.getAttribute(toggle, 'aria-expanded')) !== 'false') fail('aria-expanded not cleared')
  console.log('ok: pressing it again closes it')

  await page.click(toggle)
  await page.waitForSelector(panel, { state: 'visible' })
  await page.goto(`${base}/boards/${kb}/wiki/second-page`, { waitUntil: 'networkidle' })
  await connected()
  if (await page.isVisible('[data-role=page-details]')) fail('another page should start closed')
  console.log('ok: another page starts closed')
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
