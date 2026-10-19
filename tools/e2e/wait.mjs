// The browser half of tools/e2e/wait.sh (#1114).
//
//   node tools/e2e/wait.mjs <login-url> <base-url> <board-id> <choice-card> <words-card> <flag-card> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, choiceCard, wordsCard, flagCard, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
page.on('dialog', (d) => d.accept())
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }
const count = (sel) => page.locator(sel).count()

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

async function openCard(id) {
  await page.goto(`${base}/boards/${board}/cards/${id}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-title-form')
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // The board: each waiting card's front shows its question.
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  if (!(await page.locator(`#card-${choiceCard} [data-role=wait-mark]`).innerText()).includes('Which region?'))
    fail('the tile does not show the question')
  await shot('1-board')
  console.log('ok: the tile shows the question')

  // A choice's button answers with that choice.
  await openCard(choiceCard)
  if ((await page.locator('#wait-needs').innerText()).trim() !== 'Which region?') fail('no question in the panel')
  if ((await page.locator('#wait-choice-2').innerText()).trim() !== 'us') fail('no "us" button')
  await shot('2-panel')
  await page.click('#wait-choice-2')
  await until('the panel stayed after the choice', async () => (await count('#card-wait')) === 0)
  console.log('ok: clicking "us" answered it and the panel went')

  // An answer in words.
  await openCard(wordsCard)
  await page.fill('#wait-answer-form input[name="wait[answer]"]', 'Large')
  await page.click('#wait-answer-form button[type=submit]')
  await until('the panel stayed after the answer', async () => (await count('#card-wait')) === 0)
  console.log('ok: an answer in words answered it')

  // Turning the waiting flag off withdraws it.
  await openCard(flagCard)
  await page.click("#card-modal [phx-click='toggle_flag'][phx-value-flag='waiting']")
  await until('the panel stayed after the flag went', async () => (await count('#card-wait')) === 0)
  await shot('3-withdrawn')
  console.log('ok: turning the waiting flag off withdrew it')
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
