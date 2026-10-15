// The browser half of tools/e2e/folder-also.sh (#808, #810).
//
//   node tools/e2e/folder-also.mjs <login-url> <base-url> <board-id> <specs-id> <ideas-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, specs, ideas] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

const row = (key) => page.locator(`.wt-row[data-key="${key}"]`)
const placed = `at:${ideas}|folder:${specs}`
const acmeRows = () => page.locator('.wt-row', { hasText: 'Acme call' }).count()

// Opens a row unless it is open already (a small wiki opens whole).
async function toggle(key) {
  if ((await row(key).getAttribute('aria-expanded')) === 'true') return
  await row(key).locator('[data-toggle]').click()
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  // Specs' ⋯ menu → Also file in… → Ideas.
  const specsRow = row(`folder:${specs}`)
  await specsRow.waitFor()
  await specsRow.hover()
  await specsRow.locator('[data-menu]').click()
  const item = page.locator('[data-menu-item]', { hasText: 'Also file in' }).first()
  await item.waitFor({ timeout: 3000 }).catch(() => fail('no Also file in… on the folder menu'))
  await item.click()
  await page.locator('#tree-prompt').getByText('Also file “Specs” in…').waitFor()
  await page.locator(`#tree-targets button[phx-value-target="folder:${ideas}"]`).click()
  await page.getByText('“Specs” is also filed in Ideas.').waitFor()
  console.log('ok: Also file in… on a folder files it')

  // Ideas now opens, and holds Specs marked with the link icon.
  await row(`folder:${ideas}`).locator('[data-toggle]').waitFor({ timeout: 5000 })
  await toggle(`folder:${ideas}`)
  await row(placed).waitFor({ timeout: 5000 }).catch(() => fail('Specs is not shown in Ideas'))
  if (!(await row(placed).locator('.hero-link').count())) fail('the placed row has no link icon')
  if (await row(placed).locator('[data-drag]').count()) fail('the placed row can be dragged')
  console.log('ok: the placed folder shows in Ideas, with the link icon')

  // Opened there, it shows its own contents, and Specs at home stays shut.
  if ((await row(`folder:${specs}`).getAttribute('aria-expanded')) === 'true')
    await row(`folder:${specs}`).locator('[data-toggle]').click()
  await page.waitForFunction(k => document.querySelector(`.wt-row[data-key="${k}"]`)?.getAttribute('aria-expanded') === 'false', `folder:${specs}`)
  const before = await acmeRows()
  await toggle(placed)
  await page.locator(`.wt-row[data-key^="at:${ideas}|page:"]`, { hasText: 'Acme call' }).waitFor({ timeout: 5000 })
    .catch(() => fail('opening the placed folder did not show Acme call'))
  const homeOpen = await row(`folder:${specs}`).getAttribute('aria-expanded')
  if (homeOpen === 'true') fail('opening it in Ideas opened Specs at home too')
  if ((await acmeRows()) !== before + 1) fail(`expected one more Acme call row, saw ${await acmeRows()} (was ${before})`)

  // Its menu is the cut-down one.
  await row(placed).hover()
  await row(placed).locator('[data-menu]').click()
  const labels = await page.locator('[data-menu-item]').allTextContents()
  const want = ['Open', 'Open in a new tab', 'Take out of this folder', 'Copy link']
  if (labels.map(l => l.trim()).join('|') !== want.join('|')) fail(`placed folder menu: ${labels.join(', ')}`)
  await page.keyboard.press('Escape')

  // Specs at home opens on its own too: now both show Acme call, and
  // shutting the placed one leaves the home one open.
  await toggle(`folder:${specs}`)
  await page.waitForFunction(n => [...document.querySelectorAll('.wt-row')].filter(r => r.textContent.includes('Acme call')).length === n, before + 2, { timeout: 5000 })
    .catch(() => fail('Specs at home did not open apart from its placement'))
  await row(placed).locator('[data-toggle]').click()
  await page.waitForFunction(n => [...document.querySelectorAll('.wt-row')].filter(r => r.textContent.includes('Acme call')).length === n, before + 1, { timeout: 5000 })
    .catch(() => fail('shutting the placed folder shut Specs at home too'))
  if ((await row(`folder:${specs}`).getAttribute('aria-expanded')) !== 'true') fail('Specs at home shut with its placement')
  console.log('ok: each place opens and shuts on its own, and the menu is cut down')
} catch (e) {
  await page.screenshot({ path: '/tmp/folder-also-failure.png' })
  console.error('FAIL: ' + e.message + ' (screenshot: /tmp/folder-also-failure.png)')
  process.exitCode = 1
} finally {
  await browser.close()
}
