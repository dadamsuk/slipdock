// The browser half of tools/e2e/handoff-draft.sh (#1099).
//
//   node tools/e2e/handoff-draft.mjs <login-url> <base-url> <board-id> <card-id>
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
const next = '#handoff-form input[name="handoff[next_step]"]'
const body = '#handoff-form textarea[name="handoff[body]"]'

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  await page.click('#card-title-form a#handoff-edit')
  await page.waitForSelector('#handoff-form')
  // Something typed first, to see the draft replace it.
  await page.fill(next, 'my own words')

  await page.click('#handoff-draft')
  await until('no Generating… while it ran', async () => (await page.locator('#handoff-draft').innerText()).includes('Generating'))
  if (!(await page.locator('#handoff-draft').isDisabled())) fail('the button can be pressed again while it runs')
  console.log('ok: Auto generate says Generating… and is disabled while the model works')

  await until('the draft never reached the fields', async () => (await page.inputValue(next)) === 'Fix the webhook signature check')
  if (!(await page.inputValue(body)).includes('Gotchas: staging secret differs')) fail(`body: ${await page.inputValue(body)}`)
  await page.locator('#handoff-draft-note').waitFor()
  if (await page.locator('#card-handoff #handoff-next').count()) fail('the draft was saved without Save')
  console.log('ok: the draft fills the next step and the note, unsaved')

  // Edit it and save.
  await page.fill(next, 'Fix the webhook signature check today')
  await page.click('#handoff-form button[type=submit]')
  await until('the saved note did not appear', async () =>
    (await page.locator('#handoff-next').count()) > 0 &&
    (await page.locator('#handoff-next').innerText()).trim() === 'Fix the webhook signature check today')
  console.log('ok: edited and saved, the note shows beneath the title')
} catch (e) {
  fail(e.message)
} finally {
  await browser.close()
}
