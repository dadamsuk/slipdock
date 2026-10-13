// The browser half of tools/e2e/vault-chroot.sh (#758): KnowledgeBase's
// wiki → Hunt → a Job Hunt page, in KnowledgeBase's tree; then Job Hunt's
// own wiki, which is only its part of the vault.
//
//   node tools/e2e/vault-chroot.mjs <login-url> <base-url> <kb-id> <hunt-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, hunt] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

// The top-level rows of the tree, in order.
const topRows = () =>
  page.locator('.wt-row[aria-level="1"]').evaluateAll(rows => rows.map(r => r.innerText.trim().split('\n')[0]))

// Opens a shut folder row, clicking again if the tree's first load shut it.
async function open(title, inside) {
  const want = page.locator('.wt-row', { hasText: inside }).first()
  for (let i = 0; i < 3 && !(await want.count()); i++) {
    await page.locator('.wt-row', { hasText: title }).first().locator('[data-toggle]').click()
    await page.waitForTimeout(700)
  }
  await want.waitFor()
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // KnowledgeBase, mounted at the vault's root: Hunt among its folders.
  await page.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('.wt-row', { hasText: 'Hunt' }).first().waitFor()
  if (await page.locator('#open-in-vault, [data-tree-scope]').count()) fail('the vault switch is still there')
  const top = await topRows()
  const folders = top.filter(t => ['Archive', 'Hunt', 'Specs'].includes(t))
  if (folders.join(',') !== 'Archive,Hunt,Specs') fail('top rows: ' + top.join(' | '))

  // Into Hunt, and a Job Hunt page, still in KnowledgeBase's tree.
  await open('Hunt', 'Prep')
  await open('Prep', 'Interview Questions')
  await page.locator('.wt-row', { hasText: 'Interview Questions' }).first().locator('a').click()
  await page.waitForURL(new RegExp(`/boards/${hunt}/wiki/[^?]+\\?in=${kb}$`))
  await page.getByText('Why us?').waitFor()
  const crumbs = await page.locator('#context-crumbs').innerText()
  if (!/KnowledgeBase[\s\S]*Wiki[\s\S]*on Job Hunt/.test(crumbs)) fail('crumbs: ' + crumbs)
  await page.locator('.wt-row', { hasText: 'Archive' }).first().waitFor()
  await page.locator('.wt-row[aria-current="page"]', { hasText: 'Interview Questions' }).first().waitFor({ timeout: 5000 })
  console.log('ok: KnowledgeBase → Hunt → a Job Hunt page, in KnowledgeBase\'s tree')

  // Job Hunt's own wiki: its part of the vault, and nothing above it.
  await page.goto(`${base}/boards/${hunt}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('.wt-row', { hasText: 'Prep' }).first().waitFor()
  await page.waitForLoadState('networkidle')
  const own = await topRows()
  if (own.some(t => ['Archive', 'Specs', 'Hunt'].includes(t))) fail('Job Hunt shows above its mount: ' + own.join(' | '))
  console.log('ok: Job Hunt\'s wiki is only /Hunt')
} catch (e) {
  await page.screenshot({ path: '/tmp/vault-chroot-failure.png' })
  fail(e.message + ' (screenshot: /tmp/vault-chroot-failure.png)')
} finally {
  await browser.close()
}
