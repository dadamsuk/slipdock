// The browser half of tools/e2e/vault-inside.sh (#757).
//
//   node tools/e2e/vault-inside.mjs <login-url> <base-url> <kb-id>
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

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const inside = page.locator('[id^="vault-inside-"]', { hasText: 'pages stored on KnowledgeBase' })
  await inside.waitFor()
  if (await page.locator(`#boards a[href="/boards/${kb}"]`).count()) fail('KnowledgeBase is still among the boards')
  if (!(await page.locator('#boards').innerText()).includes('Job Hunt')) fail('Job Hunt went missing')

  // The board's own link on the tile opens the board…
  await inside.click()
  await page.waitForURL(new RegExp(`/boards/${kb}(\\?|$|/)`))
  console.log('ok: the tile names KnowledgeBase and its link opens the board')

  // …and the rest of the tile opens the vault.
  await page.goto(`${base}/`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('[id^="vault-tile-"]', { hasText: 'GMinds' }).first().click()
  await page.waitForURL(/\/vaults\/GMinds/)
  console.log('ok: the tile opens the vault')
} catch (e) {
  await page.screenshot({ path: '/tmp/vault-inside-failure.png' })
  fail(e.message + ' (screenshot: /tmp/vault-inside-failure.png)')
} finally {
  await browser.close()
}
