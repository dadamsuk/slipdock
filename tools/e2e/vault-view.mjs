// The browser half of tools/e2e/vault-view.sh (#752): home tile → the vault's
// tree → a page at its vault path → edit it.
//
//   node tools/e2e/vault-view.mjs <login-url> <base-url>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base] = process.argv.slice(2)
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

  // The home page: the vault stands beside the boards.
  await page.goto(`${base}/`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const tile = page.locator('#vaults a', { hasText: 'Notes' }).first()
  await tile.waitFor()
  if (!(await tile.innerText()).includes('Keystone · Journal Desk')) fail('tile: ' + await tile.innerText())
  await tile.click()
  await page.waitForURL(/\/vaults\/Notes$/)
  await page.waitForSelector('#vault-crumbs')

  // The vault's tree: open Specs, then the note in it.
  const specs = page.locator('.wt-row', { hasText: 'Specs' }).first()
  await specs.waitFor()
  // The tree's first load can land after a quick click and set what is
  // open itself: let it settle, and click again if the folder stayed shut.
  await page.waitForLoadState('networkidle')
  const note = page.locator('.wt-row', { hasText: 'Acme call' }).first()
  for (let i = 0; i < 3 && !(await note.count()); i++) {
    await page.locator('.wt-row', { hasText: 'Specs' }).first().locator('[data-toggle]').click()
    await page.waitForTimeout(700)
  }
  await note.waitFor()
  // Marked, so a tree torn down and drawn anew (a fresh view rather than a
  // patch) shows: the mark goes with it.
  const kept = () => page.evaluate(() => document.querySelector('[data-tree-rows]').__kept === true)
  await page.evaluate(() => { document.querySelector('[data-tree-rows]').__kept = true })
  await note.locator('a').click()
  await page.waitForURL(/\/vaults\/Notes\/Specs\/Acme%20call$/)
  await page.getByText('Went well.').waitFor()
  if (!(await kept())) fail('the tree was drawn anew opening a page')
  const crumbs = await page.locator('#vault-crumbs').innerText()
  if (!/Notes[\s\S]*Specs[\s\S]*Acme call[\s\S]*on Keystone/.test(crumbs)) fail('crumbs: ' + crumbs)

  // A page on the other board, from the same tree: still a patch.
  const offer = page.locator('.wt-row', { hasText: 'Launch' }).first()
  for (let i = 0; i < 3 && !(await offer.count()); i++) {
    await page.locator('.wt-row', { hasText: 'Plans' }).first().locator('[data-toggle]').click()
    await page.waitForTimeout(700)
  }
  await offer.locator('a').click()
  await page.waitForURL(/\/vaults\/Notes\/Plans\/Launch$/)
  await page.getByText('Start in May.').waitFor()
  if (!/on Journal Desk/.test(await page.locator('#vault-crumbs').innerText())) fail('not on Journal Desk')
  if (!(await kept())) fail('the tree was drawn anew opening a page on another board')
  console.log('ok: pages open from the tree without drawing it anew, across boards too')

  // Back to the note on the first board, and edit it, as on a board's wiki.
  await page.locator('.wt-row', { hasText: 'Acme call' }).first().locator('a').click()
  await page.getByText('Went well.').waitFor()
  if (!(await kept())) fail('the tree was drawn anew going back')

  await page.getByRole('link', { name: 'Edit', exact: true }).first().click()
  const body = page.locator('textarea[name="page[body]"]')
  await body.waitFor()
  await body.fill('Went well. Edited in the vault view.')
  await page.locator('#page-form button[type=submit], form[phx-submit=save] button[type=submit]').first().click()
  await page.getByText('Edited in the vault view.').first().waitFor({ timeout: 5000 })
  console.log('ok: tile → tree → page → edit')
} catch (e) {
  await page.screenshot({ path: '/tmp/vault-view-failure.png' })
  fail(e.message + ' (screenshot: /tmp/vault-view-failure.png)')
} finally {
  await browser.close()
}
