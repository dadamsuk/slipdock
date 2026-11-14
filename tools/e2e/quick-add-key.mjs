// The browser half of tools/e2e/quick-add-key.sh (#2871): q opens and Escape
// shuts the header's quick add; c never opens it; and a widget that keeps its
// own keys (the wiki's tree) keeps both from the page.
//
//   node tools/e2e/quick-add-key.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const fail = (w) => { throw new Error(w) }

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(300)
}
const panel = () => page.locator('#quick-add-panel').count()
// A key that should do nothing to quick add: press it, give the server time
// to answer, and look.
async function staysShut(key, where) {
  await page.keyboard.press(key)
  await page.waitForTimeout(600)
  if (await panel()) fail(`${key} opened quick add ${where}`)
}

try {
  // On a board, with the keyboard at the page.
  await open(`/boards/${board}`)
  if (await page.locator('#quick-add[phx-hook]').count()) fail('the header quick add still carries a hook')
  await staysShut('c', 'on a board')
  await page.keyboard.press('Escape') // out of the board's own c (list labels)
  await page.waitForTimeout(200)

  await page.keyboard.press('q')
  await page.waitForSelector('#quick-add-panel', { timeout: 5000 }).catch(() => fail('q did not open quick add on a board'))
  await page.keyboard.press('Escape')
  await page.waitForSelector('#quick-add-panel', { state: 'detached', timeout: 5000 }).catch(() => fail('Escape did not shut quick add'))

  // In the wiki, with the tree holding the keyboard.
  await open(`/boards/${board}/wiki`)
  const tree = page.locator('#wiki-tree-rows[data-own-keys]')
  if (!(await tree.count())) fail('the wiki tree is not marked data-own-keys')
  await tree.focus()
  const held = await page.evaluate(() => !!document.activeElement?.closest('[data-own-keys]'))
  if (!held) fail('the wiki tree did not take the focus')
  await staysShut('c', 'with the wiki tree focused')
  await staysShut('q', 'with the wiki tree focused')

  // And once the tree lets go, q is the page's again.
  await page.evaluate(() => document.activeElement?.blur())
  await page.keyboard.press('q')
  await page.waitForSelector('#quick-add-panel', { timeout: 5000 }).catch(() => fail('q did not open quick add in the wiki'))

  console.log('ok')
} finally {
  await browser.close()
}
