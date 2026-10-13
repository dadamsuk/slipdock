// The browser half of tools/e2e/tree-drag.sh (#749).
//
//   node tools/e2e/tree-drag.mjs <login-url> <base-url> <kb-id>
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

// Press on `from`, move there in steps as a hand would (the tree starts a
// drag after a few pixels), and let go at `x`/`y` on `to`.
async function drag(from, to, where = 0.5) {
  const a = await from.boundingBox()
  const b = await to.boundingBox()
  await page.mouse.move(a.x + 60, a.y + a.height / 2)
  await page.mouse.down()
  for (let i = 1; i <= 12; i++) {
    await page.mouse.move(a.x + 60, a.y + a.height / 2 + (b.y + b.height * where - a.y - a.height / 2) * (i / 12))
  }
  await page.mouse.up()
}

const row = (title) => page.locator('#wiki-tree .wt-row', { hasText: title }).first()

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await row('cat.png').waitFor()
  if (await page.locator('#wiki-tree [data-drag]').count()) fail('handles shown outside Organise mode')

  // The file onto Specs's middle: filed there, and nothing opened.
  const url = page.url()
  const pages = context.pages().length
  await drag(row('cat.png'), row('Specs'))
  await page.waitForTimeout(800)
  if (page.url() !== url) fail('the drop navigated to ' + page.url())
  if (context.pages().length !== pages) fail('the drop opened a tab')

  // Specs is open (a small wiki opens every folder): the page in it, onto
  // the top edge of Specs, lands at the top of the wiki.
  await row('Acme call').waitFor()
  await drag(row('Acme call'), row('Specs'), 0.1)
  await page.waitForTimeout(800)
  if (page.url() !== url) fail('the page drop navigated to ' + page.url())

  // A click is still a click (a press that didn't drag mustn't redraw the
  // link out from under it).
  await row('Acme call').locator('a').click()
  await page.waitForURL(/\/wiki\/acme-call$/, { timeout: 5000 })
  console.log('ok: dragged a file and a page with the mouse; a click still opens')
} catch (e) {
  await page.screenshot({ path: '/tmp/tree-drag-failure.png' })
  fail(e.message + ' (screenshot: /tmp/tree-drag-failure.png)')
} finally {
  await browser.close()
}
