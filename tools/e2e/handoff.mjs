// The browser half of tools/e2e/handoff.sh (W-1804, #1096).
//
//   node tools/e2e/handoff.mjs <login-url> <base-url> <board-id> <card-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }
const count = (sel) => page.locator(sel).count()

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

const above = async (a, b) => {
  const [ra, rb] = [await page.locator(a).boundingBox(), await page.locator(b).boundingBox()]
  return ra && rb && ra.y + ra.height <= rb.y + 1
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  const cardUrl = `${base}/boards/${board}/cards/${card}`
  await page.goto(cardUrl, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-title-form')

  // None yet: no panel, just the link on the meta line.
  if (await count('#card-handoff')) fail('a panel on a card with no handoff')
  const link = page.locator('#card-title-form a#handoff-edit')
  if ((await link.innerText()).trim() !== 'Leave a handoff') fail('no Leave a handoff link on the meta line')
  await shot('1-none')
  console.log('ok: no handoff, only the link on the meta line')

  // The link opens the form beneath the title and does not follow its href.
  await link.click()
  await until('the link opened no form', async () => (await count('#handoff-form')) > 0)
  if (page.url() !== cardUrl) fail(`the link navigated, to ${page.url()}`)
  if (await count('#card-title-form #handoff-edit')) fail('the link stayed while the form is open')
  if (!(await above('#card-title-form', '#handoff-form'))) fail('the form is not beneath the title')
  if (!(await above('#handoff-form', '#card-form'))) fail('the form is not above the flags and description')
  console.log('ok: the link opens the form beneath the title, URL unchanged')

  await page.fill('#handoff-form input[name="handoff[next_step]"]', 'Wire up the API')
  await page.fill('#handoff-form textarea[name="handoff[body]"]', 'State: schema done\nGotchas: seed 42')
  await page.click('#handoff-form button[type=submit]')
  await until('the note did not appear', async () => (await count('#handoff-next')) > 0)
  if ((await page.locator('#handoff-next').innerText()).trim() !== 'Wire up the API') fail('wrong next step shown')
  if (!(await above('#card-title-form', '#card-handoff'))) fail('the note is not beneath the title')
  if (!(await above('#card-handoff', '#card-form'))) fail('the note is not above the flags and description')
  if (await count('#card-title-form #handoff-edit')) fail('the meta line link is back beside a note')
  if (await count('#handoff-history')) fail('history shown for a single note')
  await shot('2-note')
  console.log('ok: saved; the note sits beneath the title, no history for one note')

  // Update, then save a second: the history appears and keeps the first.
  await page.click('#card-handoff #handoff-edit')
  await until('Update opened no form', async () => (await count('#handoff-form')) > 0)
  if ((await page.inputValue('#handoff-form input[name="handoff[next_step]"]')) !== 'Wire up the API') fail('form does not start from the note')
  await page.fill('#handoff-form input[name="handoff[next_step]"]', 'Run the suite')
  await page.click('#handoff-form button[type=submit]')
  await until('the second note did not appear', async () =>
    (await count('#handoff-next')) > 0 && (await page.locator('#handoff-next').innerText()).trim() === 'Run the suite')
  await page.click('#handoff-history summary')
  if (!(await page.locator('#handoff-history').innerText()).includes('Wire up the API')) fail('history lost the first note')
  await shot('3-history')
  console.log('ok: a second note brings the history, which keeps the first')

  // Clear, then Escape on the confirm box: nothing cleared, and the card,
  // behind the box, stays open (its Escape and click-away used to close it).
  await page.click('#card-handoff #handoff-edit')
  await until('no form for clear', async () => (await count('#handoff-clear')) > 0)
  await page.click('#handoff-clear')
  await page.locator('#confirm-dialog[open]').waitFor()
  await page.keyboard.press('Escape')
  await until('Escape left the confirm box open', async () => (await count('#confirm-dialog[open]')) === 0)
  await page.waitForTimeout(500)
  if (page.url() !== cardUrl) fail(`Escape on the confirm box closed the card (${page.url()})`)
  if (!(await count('#handoff-form'))) fail('Escape on the confirm box closed the handoff form')
  console.log('ok: Escape on the confirm box cancels, and the card stays open')

  // Clear: the note goes and the link comes back, the card still open, and
  // after a reload too.
  await page.click('#handoff-clear')
  // The app's own confirm dialog (confirm.js), not the browser's.
  await page.locator('#confirm-dialog [data-confirm-ok]').click()
  await until('Clear left the panel', async () => (await count('#card-handoff')) === 0)
  if (page.url() !== cardUrl) fail(`confirming Clear closed the card (${page.url()})`)
  await until('Clear did not bring the link back', async () => (await count('#card-title-form a#handoff-edit')) > 0)
  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  if (await count('#card-handoff')) fail('panel back after a reload of a cleared card')
  if (!(await count('#card-title-form a#handoff-edit'))) fail('no link after a reload of a cleared card')
  console.log('ok: Clear takes the note away and puts the link back, and it stays that way')
} catch (e) {
  fail(e.message)
} finally {
  await browser.close()
}
