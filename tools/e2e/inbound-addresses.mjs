// The browser half of tools/e2e/inbound-addresses.sh (#1245).
//
//   node tools/e2e/inbound-addresses.mjs <login-url> <base-url> <board-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 1400, height: 900 } })
await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: base })
const page = await context.newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

const text = async (sel) => (await page.locator(sel).innerText()).trim()
const clipboard = () => page.evaluate(() => navigator.clipboard.readText())

// Copy puts exactly the address shown on the clipboard; New address, once
// confirmed in the app's own dialog, shows a different one.
async function copyAndRotate(prefix, kind, label) {
  const address = await text(`#${prefix}-${kind}`)
  if (!new RegExp(`^${kind}-[a-z2-7]{26}@in\\.example\\.com$`).test(address)) fail(`${label}: shows ${address}`)

  await page.click(`#${prefix}-${kind}-copy`)
  await page.locator(`#${prefix}-${kind}-copy [data-label]`, { hasText: 'Copied' }).waitFor()
  if ((await clipboard()) !== address) fail(`${label}: Copy put ${await clipboard()} on the clipboard`)
  console.log(`ok: ${label} — Copy puts ${address} on the clipboard`)

  await page.click(`#${prefix}-rotate`)
  await page.click('[data-confirm-ok]')
  await page.locator(`#${prefix}-rotated`).waitFor()
  const fresh = await text(`#${prefix}-${kind}`)
  if (fresh === address || !fresh.startsWith(`${kind}-`)) fail(`${label}: after New address it shows ${fresh}`)
  await shot(label)
  console.log(`ok: ${label} — New address replaces it with ${fresh}`)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await open(`/boards/${board}`)
  await page.click('#board-actions .dropdown [title="More"]')
  await page.locator('#board-share-inbound').waitFor({ state: 'visible' })
  await page.click('#board-share-inbound')
  await page.locator('#board-inbound-modal').waitFor({ state: 'visible' })
  if (await page.locator('#board-inbound-page').count()) fail('board: a page address is offered before #1251')
  await copyAndRotate('board-inbound', 'card', 'board')

  await page.keyboard.press('Escape')
  await page.locator('#board-inbound-modal').waitFor({ state: 'detached' })
  console.log('ok: board — Escape closes the dialog')

  await open('/account')
  await page.locator('#account-inbound-add').waitFor()
  await copyAndRotate('account-inbound', 'add', 'account')
} finally {
  await browser.close()
}
