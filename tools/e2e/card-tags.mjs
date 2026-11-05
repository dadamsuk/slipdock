// The browser half of tools/e2e/card-tags.sh (#1727).
//
//   node tools/e2e/card-tags.mjs <login-url> <base-url> <board-id> <card-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const ok = (what) => console.log('ok: ' + what)

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const settle = () => page.waitForTimeout(500)
const isOpen = (sel) => page.locator(sel).evaluate((el) => el.matches(':popover-open'))

const headShot = async (name) => {
  if (!shots) return
  const box = await page.locator('#card-modal > div').first().boundingBox()
  await page.screenshot({ path: `${shots}/${name}.png`, clip: { x: box.x, y: box.y, width: box.width, height: Math.min(520, box.height) } })
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-title-form')
  await headShot('card-tags')

  // Only what is applied, as chips; 40 tags on the board, one row.
  const tagChips = await page.locator('#card-tags [data-role=tag-chip]').count()
  const flagChips = await page.locator('#card-flags [data-role=flag-chip]').count()
  if (tagChips !== 2) fail(`${tagChips} tag chips, want the 2 applied`)
  if (flagChips !== 1) fail(`${flagChips} flag chips, want the 1 applied`)
  const tagsBox = await page.locator('#card-tags').boundingBox()
  if (tagsBox.height > 36) fail(`the tags section is ${tagsBox.height}px tall on a 40-tag board`)
  ok('2 tag chips and 1 flag chip; the tags section is one row with 40 tags on the board')

  // The tag picker: narrows as you type, ticks, stays beside its button.
  await page.click('#card-tags-add')
  await page.waitForSelector('#card-tags-menu:popover-open')
  const visibleRows = () => page.locator('#card-tags-list [data-tag-name]:visible').count()
  if ((await visibleRows()) !== 40) fail('the picker does not list all 40 tags')
  await page.fill('#card-tag-search-input', 'tag 0')
  if ((await visibleRows()) !== 9) fail(`"tag 0" shows ${await visibleRows()} tags, want 9`)
  ok('typing narrows the list (40 → 9)')
  await page.fill('#card-tag-search-input', '')

  await page.click('#card-tag-pick-' + (await page.locator('#card-tags-list [data-tag-name="Tag 05"] button').getAttribute('id')).split('-').pop())
  await page.waitForSelector('#card-tags [data-role=tag-chip]:has-text("Tag 05")')
  if (!(await isOpen('#card-tags-menu'))) fail('the picker closed on a tick')
  // The chip lands before "+ Add", so the button moves: the picker follows it.
  await settle()
  const after = await page.locator('#card-tags-menu').boundingBox()
  const trigger = await page.locator('#card-tags-add').boundingBox()
  if (Math.abs(after.x - trigger.x) > 2 || after.y < trigger.y + trigger.height - 1 || after.y > trigger.y + trigger.height + 8)
    fail(`the picker is not beside its button after a tick (menu ${after.x},${after.y}; button ${trigger.x},${trigger.y + trigger.height})`)
  ok('ticking a tag adds its chip; the picker stays open beside its button')
  await headShot('card-tags-menu')

  // A new tag from the box, on Enter.
  await page.fill('#card-tag-search-input', 'Launch week')
  if (!(await page.locator('#card-tag-create').isVisible())) fail('no "New tag" offer for a new name')
  await page.press('#card-tag-search-input', 'Enter')
  await page.waitForSelector('#card-tags [data-role=tag-chip]:has-text("Launch week")')
  await settle()
  if ((await page.inputValue('#card-tag-search-input')) !== '') fail('the box keeps the new name after Enter')
  ok('Enter makes "Launch week" and puts it on the card')
  await page.keyboard.press('Escape')
  await settle()
  if (await isOpen('#card-tags-menu')) fail('Escape left the picker open')
  if (!(await page.locator('#card-title-form').count())) fail('Escape in the picker closed the card too')
  ok('Escape closes the picker and leaves the card open')

  // The × on a chip takes it off.
  await page.click('#card-tags [data-role=tag-chip]:has-text("Tag 03") button')
  await page.waitForSelector('#card-tags [data-role=tag-chip]:has-text("Tag 03")', { state: 'detached' })
  ok('the × on a chip takes the tag off')

  // Flags: the checklist, then the chip's ×.
  await page.click('#card-flags-add')
  await page.waitForSelector('#card-flags-menu:popover-open')
  await page.click('#card-flag-pick-blocked')
  await page.waitForSelector('#card-flag-blocked')
  ok('the flag picker puts Blocked on')
  await page.keyboard.press('Escape')
  await page.click('#card-flag-blocked button')
  await page.waitForSelector('#card-flag-blocked', { state: 'detached' })
  ok('the × on the flag chip takes it off')

  // The panel's keys open the pickers.
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('body').focus()
  await page.evaluate(() => document.activeElement && document.activeElement.blur())
  await page.keyboard.press('t')
  await page.waitForSelector('#card-tags-menu:popover-open', { timeout: 3000 })
  const focused = await page.evaluate(() => document.activeElement && document.activeElement.id)
  if (focused !== 'card-tag-search-input') fail(`"t" opened the tags but focus is on ${focused}`)
  ok('"t" opens the tag picker with the focus in its box')
  await page.keyboard.press('Escape')
  await page.evaluate(() => document.activeElement && document.activeElement.blur())
  await page.keyboard.press('f')
  await page.waitForSelector('#card-flags-menu:popover-open', { timeout: 3000 })
  ok('"f" opens the flag picker')
} finally {
  await browser.close()
}
