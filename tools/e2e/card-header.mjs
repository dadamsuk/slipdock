// The browser half of tools/e2e/card-header.sh (#1725).
//
//   node tools/e2e/card-header.mjs <login-url> <base-url> <board-id> <card-id> <epic-id> <sub-board-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, epic, subBoard, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const ok = (what) => console.log('ok: ' + what)

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 1400, height: 900 } })
const page = await context.newPage()

const open = async (id) => {
  await page.goto(`${base}/boards/${board}/cards/${id}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-title-form')
}
const headShot = async (name) => {
  if (!shots) return
  const box = await page.locator('#card-modal > div').first().boundingBox()
  await page.screenshot({ path: `${shots}/${name}.png`, clip: { x: box.x, y: box.y, width: box.width, height: Math.min(260, box.height) } })
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // --- A plain card, on a desktop -------------------------------------------
  await open(card)
  await headShot('card-header')

  const meta = page.locator('#card-meta')
  if (!(await meta.count())) fail('no #card-meta line under the title')
  const bordered = await meta.evaluate((line) =>
    [...line.querySelectorAll('*')]
      .filter((el) => {
        const s = getComputedStyle(el)
        const seen = !/rgba\(0, 0, 0, 0\)|transparent/.test(s.borderTopColor) && !/ 0\)$/.test(s.borderTopColor)
        return seen && s.borderTopStyle !== 'none' && parseFloat(s.borderTopWidth) > 0 && el.offsetParent !== null
      })
      .map((el) => el.id || el.tagName + '.' + el.className)
  )
  if (bordered.length) fail(`bordered things on the meta line: ${bordered.join(', ')}`)
  ok('the meta line has no bordered buttons')

  const metaText = (await meta.innerText()).replace(/\s+/g, ' ')
  if (!/Keystone/.test(metaText) || !/›/.test(metaText) || !new RegExp(`#${card}`).test(metaText) || !/created/.test(metaText))
    fail(`the meta line reads "${metaText}"`)
  ok(`the meta line reads "${metaText}"`)

  const title = await page.locator('#card-title').boundingBox()
  const metaBox = await meta.boundingBox()
  if (metaBox.y < title.y + title.height - 2) fail('the meta line is not under the title')
  ok('the meta line is under the title')

  const close = await page.locator('#card-modal button[aria-label=Close]').boundingBox()
  for (const id of ['card-move-board', 'handoff-edit', 'wait-ask', 'card-more']) {
    const el = page.locator(`#card-toolbar #${id}`)
    if (!(await el.count())) fail(`#${id} is not in the toolbar`)
    const b = await el.boundingBox()
    const mid = b.y + b.height / 2
    const closeMid = close.y + close.height / 2
    if (Math.abs(mid - closeMid) > 4) fail(`#${id} is not on the close button's row (${mid} vs ${closeMid})`)
    if (b.x + b.width > close.x) fail(`#${id} is not left of the close button`)
  }
  ok('Move, the handoff, Ask and ⋯ sit in the toolbar, on the close button’s row')

  const tb = await page.locator('#card-toolbar').boundingBox()
  if (tb.y + tb.height > title.y) fail('the toolbar overlaps the title')
  ok('the toolbar sits above the title')

  // ⋯ holds Duplicate, Archive and Delete; Delete asks first.
  await page.click('#card-more')
  await page.waitForSelector('#card-more-menu:popover-open')
  for (const label of ['Duplicate', 'Archive', 'Delete']) {
    if (!(await page.locator('#card-more-menu button', { hasText: label }).isVisible())) fail(`⋯ has no ${label}`)
  }
  ok('⋯ opens with Duplicate, Archive and Delete')
  await headShot('card-more-menu')
  await page.click('#card-more-menu button:has-text("Delete")')
  await page.waitForSelector('[data-confirm-ok]', { state: 'visible' })
  ok('Delete asks before it deletes')
  await page.keyboard.press('Escape')
  await page.waitForSelector('[data-confirm-ok]', { state: 'hidden' })
  if (!(await page.locator('#card-title-form').count())) fail('the card closed when the confirm was cancelled')

  // Ask opens the questions form; Left off opens the handoff form.
  await page.click('#card-toolbar #wait-ask')
  await page.waitForSelector('#wait-ask-form')
  ok('Ask opens the questions form')
  await page.click('#card-toolbar #handoff-edit')
  await page.waitForSelector('#handoff-form')
  ok('the handoff button opens the handoff form')

  // Move opens the move-to-board dialog.
  await page.click('#card-toolbar #card-move-board')
  await page.waitForSelector('#board-move form, #board-move [role=dialog], #board-move dialog[open]', { timeout: 5000 })
  ok('Move opens the move-to-board dialog')

  // --- An epic: one Open board ----------------------------------------------
  await open(epic)
  await headShot('epic-header')
  const openBoards = await page.locator('#card-modal :is(a, button):visible', { hasText: 'Open board' }).count()
  if (openBoards !== 1) fail(`an epic shows ${openBoards} "Open board"`)
  ok('an epic shows one "Open board"')
  await Promise.all([page.waitForURL(new RegExp(`/boards/${subBoard}(\\?|$)`)), page.click('#card-open-board')])
  ok('Open board opens the subcards’ board')

  // --- A phone ---------------------------------------------------------------
  await page.setViewportSize({ width: 390, height: 844 })
  await open(card)
  await page.screenshot({ path: shots ? `${shots}/phone-header.png` : '/dev/null', clip: { x: 0, y: 0, width: 390, height: 300 } }).catch(() => {})
  const items = page.locator('#card-toolbar > :is(a, button):visible')
  const tops = new Set()
  for (let i = 0; i < (await items.count()); i++) tops.add(Math.round((await items.nth(i).boundingBox()).y))
  if (tops.size !== 1) fail(`the toolbar wraps on a phone (${[...tops].join(', ')})`)
  const pt = await page.locator('#card-toolbar').boundingBox()
  const ptitle = await page.locator('#card-title').boundingBox()
  if (pt.y + pt.height > ptitle.y) fail('on a phone the toolbar overlaps the title')
  if (pt.x < 0 || pt.x + pt.width > 390) fail('on a phone the toolbar runs off the screen')
  ok('on a phone the toolbar is one row above the title')
} finally {
  await browser.close()
}
