// The browser half of tools/e2e/users-panel.sh: the Users table is
// read-only and the person panel holds its controls (#1739).
//
//   node tools/e2e/users-panel.mjs <login-url> <base-url> <person-id> <person-email>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, person, email] = process.argv.slice(2)
const shots = process.env.SHOTS
const before = process.env.BEFORE === '1'
const fail = (w) => { throw new Error(w) }
const check = (ok, what) => { if (!ok) fail(what) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'en-GB' })
const page = await ctx.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

await page.goto(`${base}/users`, { waitUntil: 'load' })
await page.waitForSelector('.phx-connected')
await page.waitForTimeout(300)
if (shots) await page.screenshot({ path: `${shots}/${before ? 'before' : 'after'}-users.png`, fullPage: true })
if (before) {
  console.log('ok: before shots taken')
  await browser.close()
  process.exit(0)
}

const row = `#person-${person}`
const panel = '#person-panel'
const settle = async (fn, what) => {
  for (let i = 0; i < 40; i++) { if (await fn()) return; await page.waitForTimeout(100) }
  fail(what)
}
const okConfirm = async () => {
  await page.locator('#confirm-dialog[open] [data-confirm-ok]').click()
}

// 1. Rows: nothing to change, one Manage link.
check(await page.locator('#people tbody :is(input, button, select, textarea, form)').count() === 0, 'a control in a row')
for (const tr of await page.locator('#people tbody tr').all()) {
  check(await tr.locator('a').count() === 1, 'a row without exactly one link')
  check((await tr.locator('a').innerText()).trim() === 'Manage', 'the row link is not Manage')
}
// Last seen: relative, with the exact time on hover (the admin signed in just now).
const seen = page.locator('#people time[id^=last-seen-]').first()
check(/ago|just now/.test(await seen.innerText()), `last seen reads "${await seen.innerText()}"`)
check(/\d{4}, \d\d:\d\d/.test(await seen.getAttribute('title') || ''), 'last seen has no exact time in its title')

// 2. A click on the row (not the link) opens the panel at ?user=<id>.
await page.locator(`${row} td`).nth(1).click()
await page.locator(panel).waitFor()
await page.waitForURL(`**/users?user=${person}`)
check((await page.locator(`${panel} h2`).innerText()).includes('e2e-person'), 'the panel names someone else')

// 3. The item limit (a free account's own allowance, so before the paid-up date).
await page.locator(`#limit-input-${person}`).fill('25')
await page.locator(`#limit-${person} button[type=submit]`).click()
await settle(async () => (await page.locator(`${row} [data-role=usage]`).innerText()).includes('/ 25 items'), 'limit not saved')

// 4. Paid up to, typed into the date field: the table's plan says so.
await page.locator(`#paid-until-date-${person} [data-role=date-display]`).focus()
await page.keyboard.type('06052031')
await page.keyboard.press('Tab')
await settle(async () => (await page.locator(`${row} [data-role=plan]`).innerText()).includes('Paid up to 6 May 2031'), 'paid-up date not saved')

// 5. Unlimited: the box and the row's badge.
await page.locator(`#unlimited-${person}`).click()
await settle(async () => (await page.locator(`${row} [data-role=roles]`).innerText()).includes('unlimited'), 'unlimited badge missing')
check(await page.locator(`#unlimited-${person}`).isChecked(), 'Unlimited is not ticked')
// What a change says is said in the panel, not in a toast: the toast
// dismisses itself with a click, and to the panel that is a click outside
// (phx-click-away), which used to close it 4.5s after every save.
await page.waitForTimeout(5500)
check(await page.locator(panel).isVisible(), 'the panel closed by itself after a save')
check((await page.locator('#panel-notice').innerText()).includes('Saved.'), 'the save was not said in the panel')
if (shots) await page.screenshot({ path: `${shots}/after-panel.png` })

// 6. Support with a reason.
await page.locator(`#support-reason-${person}`).fill('a lost card')
await page.locator(`#support-form-${person} button[type=submit]`).click()
await page.locator('li[id^=support-]', { hasText: 'a lost card' }).first().waitFor()
check((await page.locator('#panel-notice').innerText()).includes("You can read"), 'support was not said in the panel')

// 7. Disable asks in the app's own box; the panel stays open behind it.
await page.locator(`#disable-${person}`).click()
await page.locator('#confirm-dialog[open]').waitFor()
await okConfirm()
await page.locator(`#enable-${person}`).waitFor()
check(await page.locator(panel).isVisible(), 'the confirm box closed the panel')
await settle(async () => (await page.locator(`${row} [data-role=roles]`).innerText()).includes('disabled'), 'disabled badge missing')
await page.locator(`#enable-${person}`).click()
await page.locator(`#disable-${person}`).waitFor()

// 8. Close asks, shows what goes, and wants the address.
await page.locator(`#close-${person}`).click()
await page.locator('#confirm-dialog[open]').waitFor()
await okConfirm()
await page.locator('#closing').waitFor()
if (shots) await page.locator(panel).locator('> div').screenshot({ path: `${shots}/after-closing.png` })
await page.locator('#close-account-email').fill(email)
await page.locator('#close-account button[type=submit]').click()
await page.waitForURL(`${base}/users`)
await settle(async () => (await page.locator(row).count()) === 0, 'the closed account is still listed')
check(await page.locator(panel).count() === 0, 'the panel stayed open on a closed account')

// 9. Your own panel: no danger to press. Escape closes it.
await page.locator('#people a[id^=manage-]').first().click()
await page.locator(panel).waitFor()
check((await page.locator('#danger-zone').innerText()).includes("can't disable or close your own account"), 'own panel offers the danger zone')
check(await page.locator('#danger-zone button').count() === 0, 'a button in your own danger zone')
check(await page.locator('#panel-support').count() === 0, 'Support on your own panel')
await page.keyboard.press('Escape')
await page.waitForURL(`${base}/users`)
check(await page.locator(panel).count() === 0, 'Escape left the panel open')

// 10. A phone: the panel is a full-height sheet.
await page.setViewportSize({ width: 390, height: 844 })
await page.locator('#people a[id^=manage-]').first().click()
await page.locator(panel).waitFor()
await page.waitForTimeout(400) // the sheet's entrance
if (shots) await page.screenshot({ path: `${shots}/after-panel-phone.png` })

console.log('ok: read-only rows, last seen, row opens the panel, paid-up date, limit, unlimited, support, disable/enable, close, own panel, escape, phone')
await browser.close()
