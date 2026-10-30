// The browser half of tools/e2e/search-hotkey.sh.
//
//   node tools/e2e/search-hotkey.mjs <login-url> <base-url> <kb-id>
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

const box = '#deep-search input[name=q]'
const connected = () => page.waitForSelector('.phx-connected')
const inBox = () => page.$eval(box, (el) => document.activeElement === el)
const picked = () => page.$eval(box, (el) => el.value.slice(el.selectionStart, el.selectionEnd))
const press = () => page.keyboard.press('Control+Shift+S')
const until = async (test, why) => {
  try { await page.waitForFunction(test, null, { timeout: 5000 }) } catch { fail(why) }
}
const atSearch = () => until(() => location.pathname === '/search', `not on /search: ${page.url()}`)
const focused = () => until(
  () => document.activeElement === document.querySelector('#deep-search input[name=q]'),
  'the cursor is not in the search box',
)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // From the home page, and the box is ready to type in.
  await page.goto(`${base}/`, { waitUntil: 'networkidle' })
  await connected()
  await press()
  await atSearch()
  await connected()
  await focused()
  await page.keyboard.type('refunds')
  if ((await page.inputValue(box)) !== 'refunds') fail('typing did not reach the box')
  console.log('ok: from home, cursor in the box')

  // Again here: same page, the text kept and picked, typing replaces it.
  await page.evaluate(() => document.activeElement.blur())
  await press()
  await focused()
  await until(() => {
    const el = document.querySelector('#deep-search input[name=q]')
    return el.selectionEnd - el.selectionStart === 7
  }, 'the text is not selected')
  if ((await picked()) !== 'refunds') fail('the text is not selected')
  if (!(await inBox())) fail('lost the cursor')
  console.log('ok: on /search, the cursor comes back and the text is kept')

  // From Ask, what is in the box comes along.
  await page.goto(`${base}/ask`, { waitUntil: 'networkidle' })
  await connected()
  await page.fill(box, 'pricing')
  await page.evaluate(() => document.activeElement.blur())
  await press()
  await atSearch()
  await focused()
  if ((await page.inputValue(box)) !== 'pricing') fail('Ask lost the query')
  console.log('ok: from Ask, to Search with the query')

  // Mid-sentence in a box on a board, with a palette open over it too.
  await page.goto(`${base}/boards/${kb}`, { waitUntil: 'networkidle' })
  await connected()
  await page.keyboard.press('Control+o')
  await page.waitForSelector('[data-key-capture=filter]')
  await page.keyboard.type('half a thou')
  await press()
  await atSearch()
  await focused()
  if (await page.$('[data-key-capture]')) fail('the palette is still open')
  console.log('ok: from a palette on a board')
} catch (e) {
  fail(e.message)
} finally {
  await browser.close()
}
