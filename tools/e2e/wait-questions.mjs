// The browser half of tools/e2e/wait-questions.sh (#1220).
//
//   node tools/e2e/wait-questions.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

async function ask(questions) {
  await page.click('#card-title-form a#wait-ask')
  await page.waitForSelector('#wait-ask-form')
  for (let i = 0; i < questions.length; i++) {
    if (i > 0) {
      await page.click('#wait-ask-add')
      await page.waitForSelector(`#wait-ask-${i + 1}`)
    }
    await page.fill(`#wait-ask-${i + 1}`, questions[i])
  }
  // Let the last box's change land before asking.
  await page.waitForTimeout(500)
  await page.click('#wait-ask-save')
  await page.waitForSelector('#card-wait')
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  await ask(['Which region?', 'How many seats?'])
  const q1 = await page.locator('#wait-question-1').innerText()
  const q2 = await page.locator('#wait-question-2').innerText()
  if (!q1.includes('1.') || !q1.includes('Which region?')) fail(`question 1 reads ${q1}`)
  if (!q2.includes('2.') || !q2.includes('How many seats?')) fail(`question 2 reads ${q2}`)
  if (await page.locator('#wait-ask').count()) fail('Ask questions is still offered while a wait is open')
  console.log('ok: Ask questions opened a numbered series with a box each')

  // Type one answer, then have the other suggested: the typed one must stay.
  await page.fill('#wait-answer-2', '12')
  await page.waitForTimeout(500)
  await page.click('#wait-suggest-1')
  await until('the suggestion never reached box 1', async () => (await page.inputValue('#wait-answer-1')) === 'eu-west-1')
  if ((await page.inputValue('#wait-answer-2')) !== '12') fail(`box 2 lost what was typed: ${await page.inputValue('#wait-answer-2')}`)
  console.log('ok: ✨ filled box 1 from the model and box 2 kept what was typed')

  await page.click('#wait-answer')
  await until('the panel stayed after Send answers', async () => (await page.locator('#card-wait').count()) === 0)
  await page.locator('#card-wait-history summary').waitFor()
  await page.click('#card-wait-history summary')
  const history = await page.locator('#card-wait-history').innerText()
  if (!history.includes('→ eu-west-1') || !history.includes('→ 12')) fail(`history reads ${history}`)
  console.log('ok: Send answers closed it, and Questions asked before shows both answers')

  await ask(['Ready to ship?'])
  // Skip asks first, in the app's own dialog (assets/js/confirm.js).
  await page.click('#wait-skip')
  await page.locator('[data-confirm-ok]').click()
  await until('the panel stayed after Skip', async () => (await page.locator('#card-wait').count()) === 0)
  await until('history did not count two', async () =>
    (await page.locator('#card-wait-history summary').innerText()).includes('(2)'))
  console.log('ok: Skip closed the second, and the history counts two')
} catch (e) {
  fail(e.message)
} finally {
  await browser.close()
}
