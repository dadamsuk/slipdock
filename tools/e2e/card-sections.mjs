// The browser half of tools/e2e/card-sections.sh (#1728).
//
//   node tools/e2e/card-sections.mjs <login-url> <base-url> <board-id> <epic-id> <sub-board-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, epic, subBoard, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const ok = (what) => console.log('ok: ' + what)

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 1000 } })).newPage()
const settle = () => page.waitForTimeout(500)
const shot = async (name, sel) => { if (shots) await page.locator(sel).first().screenshot({ path: `${shots}/${name}.png` }) }
const underlined = () =>
  page.locator('#card-modal [data-section-key] u').evaluateAll((us) =>
    us.filter((u) => getComputedStyle(u).textDecorationLine.includes('underline')).length)

const open = async () => {
  await page.goto(`${base}/boards/${board}/cards/${epic}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-title-form')
  await page.evaluate(() => document.activeElement && document.activeElement.blur())
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await open()
  await shot('sections', '#card-modal > div')

  // Underlines only while Alt is held.
  const keyed = await page.locator('#card-modal [data-section-key] u').count()
  if (keyed < 6) fail(`${keyed} keyed letters, want at least 6`)
  if ((await underlined()) !== 0) fail(`${await underlined()} letters underlined with no key held`)
  await page.keyboard.down('Alt')
  await settle()
  if ((await underlined()) !== keyed) fail(`with Alt held ${await underlined()} of ${keyed} letters are underlined`)
  await shot('sections-alt', '#card-modal > div')
  await page.keyboard.up('Alt')
  await settle()
  if ((await underlined()) !== 0) fail('the underlines stay after Alt is let go')
  ok(`no underlines at rest; all ${keyed} while Alt is held; gone on release`)

  // The keys still jump.
  const scroller = page.locator('#card-modal')
  await page.keyboard.press('c')
  await settle()
  const top = await scroller.evaluate((el) => el.scrollTop)
  if (top < 50) fail(`"c" did not scroll to Comments (scrollTop ${top})`)
  ok('"c" still jumps to Comments')
  await page.keyboard.press('Home')
  await settle()

  // One icon rule: every section heading in the main column has an icon.
  const missing = await page.locator('#card-modal [data-section-key]').evaluateAll((secs) =>
    secs.filter((s) => !s.closest('aside'))
      .filter((s) => { const h = s.querySelector('.section-label'); return h && !h.querySelector('svg, [class*="hero-"]') })
      .map((s) => s.dataset.sectionKey))
  if (missing.length) fail(`section headings with no icon: ${missing.join(', ')}`)
  ok('every section heading has an icon')

  // Subcards: one add row with a list picker.
  const forms = await page.locator('#card-modal form[phx-submit=quick_add_subcard]').count()
  if (forms !== 1) fail(`${forms} subcard add forms, want 1`)
  const picker = page.locator('#card-modal form[phx-submit=quick_add_subcard] select[name=column_id]')
  const options = await picker.locator('option').allTextContents()
  if ((await picker.inputValue()) !== (await picker.locator('option').first().getAttribute('value'))) fail('the list picker does not start on the first list')
  await picker.selectOption({ label: options[options.length - 1].trim() })
  await page.fill('#card-modal form[phx-submit=quick_add_subcard] input[name=title]', 'Ship it')
  await page.press('#card-modal form[phx-submit=quick_add_subcard] input[name=title]', 'Enter')
  await page.waitForSelector('#card-modal li[id^=subcard-]:has-text("Ship it")')
  ok(`one add row; "Ship it" added to ${options[options.length - 1].trim()}`)
  await shot('subcards', '#card-modal section[data-section-key=s]')

  // Remove subcards is in ⋯ and asks first.
  if (await page.locator('#card-modal section[data-section-key=s] > button:has-text("Remove subcards")').count()) fail('Remove subcards is still inline')
  await page.click('#subcards-more')
  await page.waitForSelector('#subcards-more-menu:popover-open')
  await page.click('#subcards-more-menu button:has-text("Remove subcards")')
  await page.waitForSelector('[data-confirm-ok]', { state: 'visible' })
  ok('Remove subcards is in ⋯ and asks first')
  await page.click('[data-confirm-cancel]')

  // Attachments: one line when empty.
  const zone = page.locator('#card-attachments [data-role=drop-zone]')
  const box = await zone.boundingBox()
  if (!box) fail('no drop zone when there are no attachments')
  if (box.height > 40) fail(`the drop zone is ${box.height}px tall`)
  ok(`the empty attachments drop zone is one line (${Math.round(box.height)}px)`)
  await shot('attachments', '#card-attachments')
} finally {
  await browser.close()
}
