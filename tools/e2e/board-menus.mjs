// The browser half of tools/e2e/board-menus.sh (#1133).
//
//   node tools/e2e/board-menus.mjs <login-url> <base-url> <board-id> [shots-dir]
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
const page = await context.newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }
const box = async (sel) => {
  const b = await page.locator(sel).first().boundingBox()
  if (!b) fail(`${sel} is not on screen`)
  return b
}

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

// The chat and the … sit below the header, on the toolbar's row, right of
// Views; the … menu opens and its Share entry is on screen.
async function check(path, label) {
  await open(path)
  const header = await box('header')
  const views = await box('main [title="Saved views"]')
  const chat = await box('#board-chat')
  const more = await box('#board-actions .dropdown [title="More"]')
  for (const [name, b] of [['chat', chat], ['…', more]]) {
    if (b.y < header.y + header.height) fail(`${label}: the ${name} is in the header`)
    if (Math.abs(b.y + b.height / 2 - (views.y + views.height / 2)) > 4) fail(`${label}: the ${name} is not on Views' row`)
    if (b.x < views.x + views.width) fail(`${label}: the ${name} is left of Views`)
  }
  if (more.x < chat.x) fail(`${label}: the … is left of the chat`)
  if ((await page.locator('header #board-chat, header #board-actions').count()) !== 0) fail(`${label}: board buttons left in the header`)

  await page.click('#board-actions .dropdown [title="More"]')
  const share = page.locator('#board-share')
  await share.waitFor({ state: 'visible' })
  const s = await share.boundingBox()
  const vp = page.viewportSize()
  if (s.x < 0 || s.x + s.width > vp.width || s.y + s.height > vp.height) fail(`${label}: the … menu runs off the screen`)
  await page.waitForTimeout(400)
  await shot(label)
  await page.keyboard.press('Escape')
  console.log(`ok: ${label} — chat and … on the toolbar, right of Views; the menu opens whole`)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await check(`/boards/${board}`, 'laptop-board')
  await check(`/boards/${board}/table`, 'laptop-table')
  await page.setViewportSize({ width: 900, height: 900 })
  await check(`/boards/${board}`, 'tablet-board')

  // The chat still opens from its new place.
  await open(`/boards/${board}`)
  await page.click('#board-chat')
  await page.locator('#page-ai [role=dialog]').waitFor({ state: 'visible' })
  console.log('ok: the chat opens from the toolbar')
} finally {
  await browser.close()
}
