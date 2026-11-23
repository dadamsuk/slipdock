// The browser half of tools/e2e/table-pickers.sh (#3671).
//
//   node tools/e2e/table-pickers.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, id] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const shots = process.env.SHOTS

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const settle = () => page.waitForTimeout(500)
const open = (kind) => page.locator(`#${kind}-all-${id}-open`)
const menu = (kind) => page.locator(`#${kind}-all-${id}-menu`)
const row = page.locator(`tr[id$="-${id}"]`)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${board}/table?fields=title,assignee,tags,flags`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  await page.mouse.move(5, 5)
  if ((await open('tags').evaluate(e => getComputedStyle(e).opacity)) !== '0') fail('the tags button shows on a row not hovered')

  // Tags: two picked in one go, the list staying open between them.
  await row.hover()
  await open('tags').click()
  await settle()
  if (!(await menu('tags').evaluate(e => e.matches(':popover-open')))) fail('the tags button opened no list')
  // A patch that adds the first chip must not move (and so close) the list.
  await menu('tags').locator('[role=menuitemcheckbox]', { hasText: 'bug' }).click()
  await settle()
  if (!(await menu('tags').evaluate(e => e.matches(':popover-open')))) fail('the tags list closed after one pick')
  await menu('tags').locator('[role=menuitemcheckbox]', { hasText: 'ux' }).click()
  await settle()
  if (shots) await page.screenshot({ path: `${shots}/table-pickers-tags.png` })
  const tagText = await row.locator('.table-tags').innerText()
  if (!tagText.includes('bug') || !tagText.includes('ux')) fail(`the tags cell reads ${tagText}`)
  await page.keyboard.press('Escape')
  await settle()
  if (await menu('tags').evaluate(e => e.matches(':popover-open'))) fail('Escape left the tags list open')

  // Flags.
  await row.hover()
  await open('flags').click()
  await settle()
  await menu('flags').locator('[role=menuitemcheckbox]', { hasText: 'Starred' }).click()
  await settle()
  await page.keyboard.press('Escape')

  // Assignee: the signed-in person.
  await row.hover()
  await open('assignee').click()
  await settle()
  const people = menu('assignee').locator('[role=menuitemcheckbox]')
  if ((await people.count()) < 1) fail('the assignee list is empty')
  await people.first().click()
  await settle()
  if ((await people.first().getAttribute('aria-checked')) !== 'true') fail('the person picked is not checked')
  await page.keyboard.press('Escape')

  // A reload shows all three saved.
  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  if ((await menu('tags').locator('[aria-checked=true]').count()) !== 2) fail('the tags did not persist')
  if ((await menu('flags').locator('[data-pick=flag-starred][aria-checked=true]').count()) !== 1) fail('the flag did not persist')
  if ((await menu('assignee').locator('[aria-checked=true]').count()) !== 1) fail('the assignee did not persist')
  if (shots) await page.screenshot({ path: `${shots}/table-pickers-done.png` })

  console.log('ok: tags, a flag and an assignee picked from the table cells, and kept')
} finally {
  await browser.close()
}
