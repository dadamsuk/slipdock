// The browser half of tools/e2e/snooze.sh (W-1803, #1058).
//
//   node tools/e2e/snooze.mjs <login-url> <base-url> <board-id> <todo> <a> <b> <c> <d> <e>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, todo, a, b, c, d, e] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 1600, height: 900 }, timezoneId: 'Pacific/Auckland' })
const page = await context.newPage()

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

const inList = (id) => page.locator(`#cards-${todo} .kanban-card[data-id="${id}"]`).count().then(n => n > 0)
const picker = () => page.locator('#snooze-picker').count().then(n => n > 0)

async function board_page() {
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await board_page()
  // Again, now the account has the browser's timezone.
  await board_page()

  // z on the card under the pointer, then z: tomorrow.
  await page.hover(`.kanban-card[data-id="${a}"]`)
  await page.keyboard.press('z')
  await until('z opened no picker', picker)
  if (!(await page.locator('#snooze-picker').innerText()).includes('Chase the quote')) fail('picker is for another card')
  await page.keyboard.press('z')
  await until('z z left the picker open', async () => !(await picker()))
  await until('the snoozed card is still in the list', async () => !(await inList(a)))
  await until('no footer', async () => (await page.locator(`#snoozed-${todo}`).innerText()).includes('1 snoozed'))
  console.log('ok: z, z snoozed the card under the pointer until tomorrow')

  // The footer shows it in place, faded, with its day.
  await page.click(`#snoozed-${todo}`)
  const revealed = page.locator(`#snoozed-card-${a}`)
  await revealed.waitFor()
  if (!(await revealed.getAttribute('class')).includes('opacity-60')) fail('not faded')
  await page.locator(`#snoozed-card-${a} [data-role=snooze-mark]`).waitFor()
  console.log('ok: the footer reveals it, faded, 💤 with its day')

  // Open it from there and wake it.
  await revealed.click()
  await page.waitForSelector('#snooze-current')
  await page.click('#snooze-wake')
  await until('Wake now left it snoozed', async () => (await page.locator('#snooze-current').count()) === 0)
  await page.keyboard.press('Escape')
  await board_page()
  await until('the woken card is not back on top', async () =>
    (await page.locator(`#cards-${todo} .kanban-card`).first().getAttribute('data-id')) === a)
  console.log('ok: Wake now put it back at the top of its list')

  // Escape closes the picker and snoozes nothing.
  await page.hover(`.kanban-card[data-id="${b}"]`)
  await page.keyboard.press('z')
  await until('no picker for b', picker)
  await page.keyboard.press('Escape')
  await until('Escape left the picker open', async () => !(await picker()))
  if (!(await inList(b))) fail('Escape snoozed b')
  console.log('ok: Escape closes the picker')

  // An in-progress card from its panel: a note with a z in it, then a preset.
  await page.goto(`${base}/boards/${board}/cards/${c}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.click('#snooze-open')
  await until('no picker from the panel', picker)
  await page.locator('#snooze-back').waitFor()
  await page.fill('#snooze-form input[name="snooze[note]"]', 'zzz later')
  await page.waitForTimeout(500)
  if (!(await picker())) fail('typing z in the note chose a preset')
  await page.click('#snooze-week')
  await until('In a week left the picker open', async () => !(await picker()))
  await page.locator('#snooze-current').waitFor()
  console.log('ok: a note with z in it, then In a week; the panel shows the snooze')

  // Select mode: two at once, by key.
  await board_page()
  await page.click('#select-mode-toggle')
  await page.click(`.kanban-card[data-id="${d}"]`)
  await page.click(`.kanban-card[data-id="${e}"]`)
  await page.click('#bulk-snooze')
  await until('no picker for the selection', picker)
  if (!(await page.locator('#snooze-picker').innerText()).includes('2 cards')) fail('picker is not for 2 cards')
  await page.keyboard.press('m')
  await until('m left the picker open', async () => !(await picker()))
  await until('a picked card is still in the list', async () => !(await inList(d)) && !(await inList(e)))
  console.log('ok: select mode snoozed both, Next Monday by its key')
} catch (err) {
  fail(err.stack || String(err))
} finally {
  await browser.close()
}
