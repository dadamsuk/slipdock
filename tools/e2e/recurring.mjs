// The browser half of tools/e2e/recurring.sh (W-1802, #1053).
//
//   node tools/e2e/recurring.mjs <login-url> <base-url> <board-id> <card-id>
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
// A browser somewhere other than UTC, so adopting its timezone shows.
const context = await browser.newContext({ viewport: { width: 1600, height: 900 }, timezoneId: 'America/New_York' })
const page = await context.newPage()

async function expectText(selector, want) {
  for (let i = 0; i < 40; i++) {
    const el = page.locator(selector).first()
    if (await el.count()) {
      const got = (await el.innerText()).replace(/\s+/g, ' ').trim()
      if (got.includes(want)) return
    }
    await page.waitForTimeout(250)
  }
  const got = (await page.locator(selector).first().count()) ? await page.locator(selector).first().innerText() : '(missing)'
  fail(`${selector} says ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // The first connected page adopts the browser's zone; Account shows it.
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.goto(`${base}/account`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const tz = await page.locator('#profile-form select[name="user[timezone]"]').inputValue()
  if (tz !== 'America/New_York') fail(`Account says ${tz}`)
  console.log('ok: the account took the browser\'s timezone (America/New_York)')

  // Repeat…: a custom rule, previewed as it is typed.
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.click('#repeat-edit')
  await expectText('#repeat-summary', 'Every week on Tue, 07:00 America/New_York')
  await page.selectOption('#repeat-form select[name="repeat[preset]"]', 'custom')
  await page.waitForSelector('#repeat-form input[name="repeat[custom]"]')
  await page.fill('#repeat-form input[name="repeat[custom]"]', 'month last fri')
  await page.fill('#repeat-form input[name="repeat[at]"]', '09:00')
  await page.locator('#repeat-form input[name="repeat[at]"]').dispatchEvent('change')
  await expectText('#repeat-summary', 'Every month on the last Friday, 09:00 America/New_York')
  await expectText('#repeat-dates', 'Fri 29 Jan 2027')
  console.log('ok: the form previews a custom rule')

  await page.click('#repeat-form button[type=submit]')
  await expectText('#repeat-current', '↻ Every month on the last Friday, 09:00 America/New_York')
  await expectText('#repeat-state', 'Next due Fri 29 Jan')
  await page.click('#repeat-skip')
  await expectText('#repeat-state', 'Next due Fri 26 Feb')
  await page.click('#repeat-pause')
  await expectText('#repeat-state', 'Paused.')
  await page.click('#repeat-pause')
  await expectText('#repeat-state', 'Next due Fri 26 Feb')
  console.log('ok: saved, skipped one, paused and resumed')

  // The front of the card.
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const mark = page.locator(`.kanban-card[data-id="${card}"] [data-role=recurrence-mark]`).first()
  await mark.waitFor()
  const title = await mark.getAttribute('title')
  if (!title.startsWith('Repeats: Every month on the last Friday')) fail(`↻ title is ${title}`)
  console.log('ok: ↻ on the card front, the rule as its tooltip')

  // Duplicate opens the copy.
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.click('#duplicate-card')
  for (let i = 0; i < 40 && page.url().includes(`/cards/${card}`); i++) await page.waitForTimeout(250)
  const copy = page.url().match(/\/cards\/(\d+)/)?.[1]
  if (!copy || copy === card) fail(`still on ${page.url()}`)
  await expectText('#flash-group', `Duplicated as #${copy}.`)
  console.log(`ok: Duplicate opened the copy, #${copy}`)
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
