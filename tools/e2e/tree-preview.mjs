// The browser half of tools/e2e/tree-preview.sh (#760).
//
//   node tools/e2e/tree-preview.mjs <login-url> <base-url> <kb-id>
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
const context = await browser.newContext({ viewport: { width: 1400, height: 900 } })
const page = await context.newPage()

const row = (title) => page.locator('#wiki-tree .wt-row', { hasText: title }).first()
const preview = page.locator('#wiki-tree-preview')

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await row('Acme call').waitFor()

  // Rest on the page: its preview, with its body, beside the tree.
  const url = page.url()
  await row('Acme call').hover()
  await preview.waitFor({ state: 'visible', timeout: 3000 })
  const text = await preview.innerText()
  if (!text.includes('Acme call') || !text.includes('Went well.')) fail('preview says: ' + text)
  const tree = await page.locator('#wiki-tree').boundingBox()
  const box = await preview.boundingBox()
  if (box.x < tree.x + tree.width) fail('the preview covers the tree')
  if (page.url() !== url) fail('hovering navigated')
  await page.screenshot({ path: '/tmp/tree-preview.png' })

  // On to a folder: it goes.
  await row('Specs').hover()
  await preview.waitFor({ state: 'hidden', timeout: 3000 })

  // From the keyboard: Space on the highlighted page, and Space again.
  await page.locator('#wiki-tree [data-tree-rows]').focus()
  await page.keyboard.press('End')
  await page.keyboard.press('Space')
  await preview.waitFor({ state: 'visible', timeout: 3000 })
  await page.keyboard.press('Space')
  await preview.waitFor({ state: 'hidden', timeout: 3000 })
  console.log('ok: a resting mouse and Space preview a page; a folder puts it away (screenshot: /tmp/tree-preview.png)')
} catch (e) {
  await page.screenshot({ path: '/tmp/tree-preview-failure.png' })
  fail(e.message + ' (screenshot: /tmp/tree-preview-failure.png)')
} finally {
  await browser.close()
}
