// The browser half of tools/e2e/my-work-waiting.sh (#1118).
//
//   node tools/e2e/my-work-waiting.mjs <login-url> <base-url> <board-id> <choice-card> <words-card> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, choiceCard, wordsCard, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }
const count = (sel) => page.locator(sel).count()
const header = async () => (await count('#waiting-count')) ? (await page.locator('#waiting-count').innerText()).trim() : null

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

async function visit(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // The number is in the header wherever you are.
  for (const path of ['/', `/boards/${board}`, '/favourites']) {
    await visit(path)
    if ((await header()) !== '2') fail(`header shows ${await header()} on ${path}`)
  }
  await shot('1-header')
  console.log('ok: the header shows 2 on every page')

  // Clicking it goes to My work, which opens with both.
  await Promise.all([page.waitForURL(`${base}/work`), page.click('#waiting-link')])
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#work-waiting')
  if ((await count('#work-waiting li')) !== 2) fail('My work does not list both')
  if (!(await page.locator(`#waiting-card-${choiceCard}`).innerText()).includes('Waiting on you: Which region?'))
    fail('no question on the item')
  await shot('2-my-work')
  console.log('ok: My work opens with both waits')

  // A choice's button answers with that choice.
  await page.click(`#waiting-card-${choiceCard} button[phx-value-choice="2"]`)
  await until('the choice item stayed', async () => (await count(`#waiting-card-${choiceCard}`)) === 0)
  if ((await header()) !== '1') fail(`header shows ${await header()} after one answer`)
  console.log('ok: clicking "us" answered it; the header says 1')

  // An answer in words.
  await page.fill(`#waiting-answer-${wordsCard} input[name="wait[answer]"]`, 'Large')
  await page.click(`#waiting-answer-${wordsCard} button[type=submit]`)
  await until('the section stayed', async () => (await count('#work-waiting')) === 0)
  if ((await header()) !== null) fail('the header number stayed')
  await shot('3-answered')
  console.log('ok: an answer in words answered it; no section, no number')
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
