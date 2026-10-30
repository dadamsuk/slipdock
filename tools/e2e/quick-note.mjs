// The browser half of tools/e2e/quick-note.sh.
//
//   node tools/e2e/quick-note.mjs <login-url> <base-url> <kb-id>
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

const panel = '#quick-note-panel'
const box = '#quick-note-panel textarea'
const connected = () => page.waitForSelector('.phx-connected')
const press = () => page.keyboard.press('Shift+Alt+KeyN')

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // The button, from home.
  await page.goto(`${base}/`, { waitUntil: 'networkidle' })
  await connected()
  await page.click('#quick-note-open')
  await page.waitForSelector(box)
  await page.keyboard.press('Escape')
  await page.waitForSelector(panel, { state: 'detached' })
  console.log('ok: the button opens it, Escape closes it')

  // The key, from a board, with the cursor in the box ready to type.
  await page.goto(`${base}/boards/${kb}`, { waitUntil: 'networkidle' })
  await connected()
  await press()
  await page.waitForSelector(box)
  await page.waitForFunction((b) => document.activeElement === document.querySelector(b), box)
  await page.keyboard.type('Ring the printers')
  await page.keyboard.press('Enter')
  await page.keyboard.type('about the banners')
  const typed = await page.inputValue(box)
  if (typed !== 'Ring the printers\nabout the banners') fail(`Enter should be a new line: ${JSON.stringify(typed)}`)
  console.log('ok: the key opens it from a board, Enter is a new line')

  // Ctrl-Enter saves and the place comes back.
  await page.keyboard.press('Control+Enter')
  await page.waitForSelector('#quick-note-where')
  const where = (await page.textContent('#quick-note-where')).trim()
  if (!where.endsWith('/ Specs')) fail(`location: ${where}`)
  const title = (await page.textContent('#quick-note-saved a')).trim()
  if (!/^\d{4}-\d\d-\d\d \d\d\.\d\d Printers banners$/.test(title)) fail(`title: ${title}`)
  if ((await page.inputValue(box)) !== '') fail('the box should be empty for the next note')
  console.log(`ok: saved as "${title}" in ${where}`)

  // The same key shuts it, even with the cursor in it.
  await press()
  await page.waitForSelector(panel, { state: 'detached' })
  console.log('ok: the key closes it')

  await page.screenshot({ path: 'tmp/quick-note.png' })
} finally {
  await browser.close()
}
