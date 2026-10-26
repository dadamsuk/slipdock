// The browser half of tools/e2e/page-link.sh: the [[ page picker in the wiki
// editor and a card's description, and the card's attach box.
//
//   node tools/e2e/page-link.mjs <login-url> <base-url> <board-id> <card-id> <spec-id> <spec-code>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, card, spec, specCode] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })
const errors = []
page.on('pageerror', (e) => { if (!page.url().includes('/login')) errors.push(`${e.message} @ ${page.url()}`) })

const menu = 'ul[data-page-link-menu]:not(.hidden)'
const menuTitles = () => page.locator(`${menu} li a span.block:first-child`).allInnerTexts()

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // --- [[ in the wiki page's editor ------------------------------------
  await page.goto(`${base}/boards/${kb}/wiki/acme-call/edit`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const content = '[id^=page-body-editor] .md-editor .cm-content'
  await page.locator(content).click()
  await page.keyboard.press('Control+End')
  await page.keyboard.press('Enter')
  await page.keyboard.type('See [[')
  await page.waitForSelector(menu, { timeout: 5000 })
  const recent = await menuTitles()
  // Billing spec was written last, so it heads the list.
  if (recent[0] !== 'Billing spec') fail(`recent first: ${JSON.stringify(recent)}`)
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/page-link-recent.png` })
  // By folder and title.
  await page.keyboard.type('specs/bil')
  await page.waitForFunction((m) => document.querySelector(m + ' li a')?.innerText.includes('Billing spec'), menu)
  await page.keyboard.press('Enter')
  await page.keyboard.type(' now')
  if (await page.locator(menu).count()) fail('the picker stayed open after taking a page')
  const textarea = await page.locator('#page_body').inputValue()
  if (!textarea.includes('See [[Billing spec]] now')) fail(`editor text: ${JSON.stringify(textarea)}`)
  await page.locator('#page-form button[type=submit]').first().click()
  await page.waitForURL(/\/wiki\/acme-call$/)

  // --- [[ in a card's description, by code -------------------------------
  await page.goto(`${base}/boards/${kb}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator("button[phx-click='edit_description']").first().click()
  const desc = '[id^=card-description-editor] .md-editor .cm-content'
  await page.locator(desc).waitFor()
  await page.locator(desc).click()
  await page.keyboard.type('Per [[acme')
  await page.waitForFunction((m) => document.querySelector(m + ' li a')?.innerText.includes('Acme call'), menu)
  // Arrow keys and Enter are the picker's, not the editor's.
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('ArrowUp')
  await page.keyboard.press('Enter')
  const d = await page.locator('#card-description').inputValue()
  if (d !== 'Per [[Acme call]]') fail(`description text: ${JSON.stringify(d)}`)
  // Escape closes an open picker without leaving the description.
  await page.keyboard.type(' and [[')
  await page.waitForSelector(menu)
  await page.keyboard.press('Escape')
  if (await page.locator(menu).count()) fail('Escape did not close the picker')
  if (!(await page.locator(desc).count())) fail('Escape in the picker stopped editing the description')
  for (let i = 0; i < 7; i++) await page.keyboard.press('Backspace')
  await page.waitForTimeout(900)
  await page.locator("button[phx-click='stop_editing_description']").first().click()
  await page.waitForSelector('#card-description-view')

  // --- The attach box -------------------------------------------------------
  const box = '#card-doc-search input[name=q]'
  await page.locator(box).click()
  await page.waitForSelector("button[phx-click='attach_doc']")
  const first = await page.locator("button[phx-click='attach_doc'] span.block").first().innerText()
  // Acme call was saved just now, above: the most recent.
  if (first !== 'Acme call') fail(`attach box recent first: ${first}`)
  await page.locator(box).fill(specCode)
  const btn = `button[phx-click='attach_doc'][phx-value-page='${spec}']`
  // A code is that page, ahead of anything its letters happen to match.
  await page.waitForFunction((id) =>
    document.querySelector("button[phx-click='attach_doc']")?.getAttribute('phx-value-page') === id, spec,
    { timeout: 5000 }).catch(() => fail('a code should put its page first'))
  await page.locator(btn).click()
  await page.waitForFunction(() => document.body.innerText.includes('Attached'))

  if (errors.length) fail(`page errors: ${errors.join('; ')}`)
  console.log('ok: the [[ picker and the attach box, in Chromium')
} finally {
  await browser.close()
}
