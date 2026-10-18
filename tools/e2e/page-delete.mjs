// The browser half of tools/e2e/page-delete.sh (#1098).
//
//   node tools/e2e/page-delete.mjs <login-url> <base-url> <board-id> <scratch> <kept> <scratch-slug> <acme>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, scratch, kept, slug, acme] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const row = (key) => page.locator(`.wt-row[data-key="${key}"]`)
const menuItem = (text) => page.locator('[data-tree-menu] [data-menu-item]', { hasText: text })

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // Reading Scratch, the page about to go.
  await page.goto(`${base}/boards/${kb}/wiki/${slug}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await row(`page:${scratch}`).waitFor()

  // Right-click → Delete… → the prompt, with the child counted → Cancel.
  await row(`page:${scratch}`).click({ button: 'right' })
  await menuItem('Delete…').waitFor()
  const labels = await page.locator('[data-tree-menu] [data-menu-item], [data-tree-menu] a').allInnerTexts()
  if (labels.map(l => l.trim()).indexOf('Delete…') !== labels.length - 1) fail(`Delete… is not last: ${labels}`)
  await menuItem('Delete…').click()
  await page.locator('#tree-prompt').getByText('Delete “Scratch”?').waitFor()
  const warning = await page.locator('#tree-delete-page-warning').innerText()
  if (!warning.includes('The 1 page under it will be kept')) fail(`warning: ${warning}`)
  await page.locator('#tree-prompt button', { hasText: 'Cancel' }).click()
  await until('Cancel left the prompt', async () => (await page.locator('#tree-prompt').count()) === 0)
  if (!(await row(`page:${scratch}`).count())) fail('Cancel took the page away')
  console.log('ok: right-click → Delete… asks, counting the page under it; Cancel keeps it')

  // Again, and Delete for good: the wiki, without it, its child at the top.
  await row(`page:${scratch}`).click({ button: 'right' })
  await menuItem('Delete…').click()
  await page.locator('#tree-delete-page-confirm').click()
  await until('the page is still in the tree', async () => (await row(`page:${scratch}`).count()) === 0)
  await until(`still on the deleted page: ${page.url()}`, async () => page.url() === `${base}/boards/${kb}/wiki`)
  await until('Kept is not at the top of the tree', async () => (await row(`page:${kept}`).count()) > 0)
  console.log('ok: Delete for good takes it, leaves its page, keeps its child')

  // By the ⋯ button, on a page in a folder that isn't open: it stays here.
  const acmeRow = row(`page:${acme}`)
  await acmeRow.waitFor()
  await acmeRow.hover()
  await acmeRow.locator('[data-menu]').click()
  await menuItem('Delete…').click()
  await page.locator('#tree-prompt').getByText('Delete “Acme call”?').waitFor()
  await page.locator('#tree-delete-page-confirm').click()
  await until('Acme call is still in the tree', async () => (await row(`page:${acme}`).count()) === 0)
  if (page.url() !== `${base}/boards/${kb}/wiki`) fail(`moved to ${page.url()}`)
  console.log('ok: the ⋯ menu deletes too')
} catch (e) {
  fail(e.message)
} finally {
  await browser.close()
}
