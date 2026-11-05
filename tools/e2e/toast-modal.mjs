// The browser half of tools/e2e/toast-modal.sh: a self-closing toast (the
// AutoDismiss hook) leaves an open modal open, and clicking a toast still
// clears it (#1847).
//
//   node tools/e2e/toast-modal.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (w) => { throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

page.on('pageerror', e => console.error('pageerror:', e.message))
page.on('console', m => { if (m.type() === 'error') console.error('console:', m.text()) })
const modal = page.locator('#automations-modal')
const toast = page.locator('#flash-info')

// Adds the first ready-made rule with its defaults, which flashes an info toast.
async function addRule() {
  await page.locator('[phx-click="pick_rule_preset"]').first().click()
  const form = page.locator('form[phx-submit="create_rule_preset"]')
  await form.waitFor({ state: 'visible' })
  await form.locator('button[type=submit]').first().click()
  await toast.waitFor({ state: 'visible', timeout: 5000 })
}

try {
  await page.goto(`${base}/boards/${board}/automations`)
  await page.waitForSelector('.phx-connected')
  await modal.waitFor({ state: 'visible' })

  // 1. The toast closes by itself and the modal stays open.
  await addRule()
  const shownAt = Date.now()
  await toast.waitFor({ state: 'hidden', timeout: 8000 })
  const after = Date.now() - shownAt
  if (after < 3500) fail(`the toast went after ${after}ms, before its time`)
  await page.waitForTimeout(500)
  if (!(await modal.isVisible())) fail('the modal closed when the toast dismissed itself')
  if (!page.url().endsWith('/automations')) fail(`the URL left the modal: ${page.url()}`)
  if (shots) await page.screenshot({ path: `${shots}/toast-modal-after.png` })
  console.log(`ok: toast dismissed itself after ~${after}ms; modal still open`)

  // 2. Clicking the toast's close button still clears it at once.
  await addRule()
  await toast.locator('button[aria-label=close]').click()
  await toast.waitFor({ state: 'hidden', timeout: 2000 })
  console.log('ok: the close button clears the toast')
} catch (e) {
  if (shots) await page.screenshot({ path: `${shots}/toast-modal-fail.png` })
  console.error('FAIL:', e.message)
  process.exitCode = 1
} finally {
  await browser.close()
}
