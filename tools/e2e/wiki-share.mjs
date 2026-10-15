// The browser half of tools/e2e/wiki-share.sh (#814).
//
//   node tools/e2e/wiki-share.mjs <login-url> <base-url> <board-id> <page-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, pageId] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })
const row = (key) => page.locator(`.wt-row[data-key="${key}"]`)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${kb}/wiki/acme-call`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  // The page's ⋯ menu → Share…
  await page.locator('[title="Page actions"]').click()
  await page.locator('#share-page').click()
  const modal = page.locator('#share-modal')
  await modal.getByText('Share “Acme call”').waitFor({ timeout: 5000 }).catch(() => fail('no Share dialog'))

  await modal.locator('input[name=email]').fill('friend@example.com')
  await modal.locator('select[name=level]').selectOption('write')
  await modal.locator('button[type=submit]', { hasText: 'Share' }).click()
  await modal.locator('li[id^="grant-page-"]', { hasText: 'friend@example.com' }).waitFor({ timeout: 5000 })
    .catch(() => fail('the grant did not show in the dialog'))
  const level = await modal.locator('li[id^="grant-page-"] .badge').textContent()
  if (level.trim() !== 'can edit') fail(`expected can edit, saw ${level}`)
  console.log('ok: shared with friend@example.com, can edit')

  await modal.locator('button[aria-label=Close]').click()
  await page.locator('#share-modal').waitFor({ state: 'detached' })

  // The tree marks it, and its own menu has Share… too.
  await row(`page:${pageId}`).locator('[data-shared]').waitFor({ timeout: 5000 })
    .catch(() => fail('the tree row has no shared mark'))
  console.log('ok: the tree marks the page shared')

  await row(`page:${pageId}`).hover()
  await row(`page:${pageId}`).locator('[data-menu]').click()
  await page.locator('[data-menu-item]', { hasText: 'Share…' }).click()
  await modal.locator('li[id^="grant-page-"]', { hasText: 'friend@example.com' }).waitFor({ timeout: 5000 })
    .catch(() => fail("the tree's Share… did not open the dialog"))
  console.log("ok: the tree's Share… opens the same dialog")

  // Take it back.
  await modal.locator('li[id^="grant-page-"] button[title="Remove access"]').click()
  await modal.locator('li[id^="grant-page-"]').waitFor({ state: 'detached', timeout: 5000 })
    .catch(() => fail('the grant did not go'))
  await modal.locator('button[aria-label=Close]').click()
  await row(`page:${pageId}`).locator('[data-shared]').waitFor({ state: 'detached', timeout: 5000 })
    .catch(() => fail('the shared mark stayed after the share was taken back'))
  console.log('ok: taking it back clears the dialog and the mark')
} finally {
  await browser.close()
}
