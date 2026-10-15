// The browser half of tools/e2e/shared-tree.sh (#817).
//
//   node tools/e2e/shared-tree.mjs <owner-login> <friend-login> <base-url> <board-id> <specs-id> <page-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [ownerLogin, friendLogin, base, kb, specs, pageId] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})

async function signIn(link) {
  const context = await browser.newContext({ viewport: { width: 1400, height: 900 } })
  const page = await context.newPage()
  await page.goto(link, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  return page
}

try {
  const owner = await signIn(ownerLogin)
  const friend = await signIn(friendLogin)

  // The friend's Shared view, open before anything is shared.
  await friend.goto(`${base}/shared`, { waitUntil: 'networkidle' })
  await friend.waitForSelector('.phx-connected')
  await friend.locator('#shared-empty').waitFor().catch(() => fail('the Shared view did not say it was empty'))

  // The owner shares Specs from the tree's ⋯ menu, can edit.
  await owner.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await owner.waitForSelector('.phx-connected')
  const specsRow = owner.locator(`.wt-row[data-key="folder:${specs}"]`)
  await specsRow.waitFor()
  await specsRow.hover()
  await specsRow.locator('[data-menu]').click()
  await owner.locator('[data-menu-item]', { hasText: 'Share…' }).click()
  const modal = owner.locator('#share-modal')
  await modal.getByText('Share “Specs”').waitFor({ timeout: 5000 }).catch(() => fail('no Share dialog for the folder'))
  await modal.locator('input[name=email]').fill('friend@example.com')
  await modal.locator('select[name=level]').selectOption('write')
  await modal.locator('button[type=submit]', { hasText: 'Share' }).click()
  await modal.locator('li[id^="grant-folder-"]', { hasText: 'friend@example.com' }).waitFor({ timeout: 5000 })
  console.log('ok: the owner shared Specs from the tree')

  // It turns up on the friend's screen without a reload.
  await friend.locator(`#shared-tree a[data-key="page:${pageId}"]`).waitFor({ timeout: 5000 })
    .catch(() => fail('the share did not show up live'))
  const text = await friend.locator('#shared-view').textContent()
  if (text.includes('Keystone')) fail('the Shared view names the board')
  console.log('ok: Specs and Acme call show under Shared with me, live, without the board')

  // The friend opens the page and edits it.
  await friend.locator(`#shared-tree a[data-key="page:${pageId}"]`).click()
  await friend.locator('#shared-page h1', { hasText: 'Acme call' }).waitFor()
  await friend.locator('#shared-edit').click()
  await friend.locator('#shared-edit-form textarea').fill('Went well. Edited by a friend.')
  await friend.locator('#shared-edit-form button[type=submit]').click()
  await friend.locator('#shared-page', { hasText: 'Edited by a friend.' }).waitFor({ timeout: 5000 })
    .catch(() => fail('the edit did not show'))
  console.log('ok: the friend edited the shared page')

  // The owner takes it back; the friend's page goes, with a word.
  await modal.locator('li[id^="grant-folder-"] button[title="Remove access"]').click()
  await modal.locator('li[id^="grant-folder-"]').waitFor({ state: 'detached', timeout: 5000 })
  await friend.waitForURL(`${base}/shared`, { timeout: 5000 }).catch(() => fail('the friend stayed on a revoked page'))
  await friend.locator('#shared-empty').waitFor({ timeout: 5000 })
  console.log('ok: taking the share back clears the friend\'s view live')
} finally {
  await browser.close()
}
