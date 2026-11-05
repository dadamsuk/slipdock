// The browser half of tools/e2e/buttons.sh (#1703): the button hierarchy.
// In light and dark:
//   - a primary button is filled with the primary, its label in
//     primary-content (the old one was a 16% tint that read as disabled);
//   - a secondary button is a soft tint with the primary for its words,
//     and is not the solid fill;
//   - a plain button is the base-100 surface with a hairline, not the old
//     near-black outline;
//   - no page carries `btn-outline`;
//   - beside a field, the button is 28px (`btn-sm`) and shares the field's
//     bottom edge: Account → Profile's Save, Config → Email's Send test and
//     its Send a code.
// BEFORE=1 only takes the screenshots (for the card's before/after).
//
//   node tools/e2e/buttons.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const before = process.env.BEFORE === '1'
const fail = (w) => { if (!before) throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path, scheme) => {
  await page.emulateMedia({ colorScheme: scheme })
  await page.goto(base + path, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.addStyleTag({ content: '*, *::before { transition: none !important; animation: none !important; }' })
}
const shot = async (name, sel) => {
  if (!process.env.SHOTS) return
  const path = `${process.env.SHOTS}/${before ? 'before' : 'after'}-${name}.png`
  if (sel) await page.locator(sel).first().screenshot({ path })
  else await page.screenshot({ path })
}

// A button's look: its box, and its colours as rgb over base-100.
const look = (sel) => page.evaluate((sel) => {
  const el = [...document.querySelectorAll(sel)].find((e) => e.offsetParent !== null)
  if (!el) return null
  const cv = document.createElement('canvas'); cv.width = cv.height = 1
  const cx = cv.getContext('2d', { willReadFrequently: true })
  const body = getComputedStyle(document.body)
  const rgb = (c) => {
    cx.fillStyle = body.getPropertyValue('--color-base-100'); cx.fillRect(0, 0, 1, 1)
    cx.fillStyle = c; cx.fillRect(0, 0, 1, 1)
    return cx.getImageData(0, 0, 1, 1).data.slice(0, 3).join(',')
  }
  const s = getComputedStyle(el)
  const r = el.getBoundingClientRect()
  return {
    top: r.top, bottom: r.bottom, h: r.height,
    bg: rgb(s.backgroundColor), fg: rgb(s.color), border: rgb(s.borderTopColor),
    borderWidth: parseFloat(s.borderTopWidth),
    primary: rgb(body.getPropertyValue('--color-primary')),
    primaryContent: rgb(body.getPropertyValue('--color-primary-content')),
    base100: rgb(body.getPropertyValue('--color-base-100')),
    text: rgb(body.getPropertyValue('--color-base-content')),
  }
}, sel)

// A button and the field beside it share a bottom edge, and the button is
// the field's 28px.
const beside = async (where, buttonSel, fieldSel) => {
  const b = await look(buttonSel), f = await look(fieldSel)
  if (!b || !f) return fail(`${where}: no ${b ? fieldSel : buttonSel}`)
  if (Math.round(b.h) !== 28) fail(`${where}: the button is ${b.h}px tall, not btn-sm's 28px`)
  if (Math.abs(b.bottom - f.bottom) > 1) fail(`${where}: the button's bottom is ${(b.bottom - f.bottom).toFixed(1)}px off the field's`)
  return { button: b.h, offset: +(b.bottom - f.bottom).toFixed(1) }
}

const outlines = () => page.evaluate(() => document.querySelectorAll('.btn-outline').length)

const results = {}
for (const scheme of ['light', 'dark']) {
  const r = (results[scheme] = {})

  await open('/account', scheme)
  const save = await look('#profile-form button[type=submit]')
  if (save.bg !== save.primary) fail(`${scheme}: Save is ${save.bg}, not the solid primary ${save.primary}`)
  if (save.fg !== save.primaryContent) fail(`${scheme}: Save's label is ${save.fg}, not primary-content`)
  r.profile = await beside(`${scheme} Account → Profile`, '#profile-form button[type=submit]', '#profile-form input[type=text]')
  if (await outlines()) fail(`${scheme}: Account still has btn-outline`)
  await shot(`account-${scheme}`, '#profile-form')

  // Sign out lives in Account → Sign-in & passkeys (#1737).
  await open('/account/sign-in', scheme)
  const signOut = await look('a[href="/logout"].btn')
  if (signOut.border === signOut.text) fail(`${scheme}: Sign out still draws a base-content border`)
  if (signOut.borderWidth !== 1) fail(`${scheme}: Sign out's border is ${signOut.borderWidth}px, not a 1px hairline`)
  if (await outlines()) fail(`${scheme}: Sign-in & passkeys still has btn-outline`)

  await open('/account/data', scheme)
  const tint = await look('.btn-secondary')
  if (!tint) fail(`${scheme}: no secondary button on Account → Data`)
  else {
    if (tint.bg === tint.primary) fail(`${scheme}: the secondary is the solid primary`)
    if (tint.bg === tint.base100) fail(`${scheme}: the secondary has no tint`)
    if (tint.fg !== tint.primary) fail(`${scheme}: the secondary's words are ${tint.fg}, not the primary`)
  }

  await open('/config/mail', scheme)
  r.mailTest = await beside(`${scheme} Config → Email test`, 'button[value=test]', 'input[name$="[test_to]"]')
  r.adminEmail = await beside(`${scheme} Config → Admin address`, '#admin-email-form button[type=submit]', '#admin-email-form input')
  if (await outlines()) fail(`${scheme}: Config → Email still has btn-outline`)
  await shot(`config-mail-${scheme}`)

  await open('/users', scheme)
  if (await outlines()) fail(`${scheme}: Users still has btn-outline`)
  await shot(`users-${scheme}`)

  await open(`/boards/${board}/wiki/new`, scheme)
  const wikiSave = await look('#page-form button[type=submit]')
  if (wikiSave && wikiSave.bg !== wikiSave.primary) fail(`${scheme}: the wiki editor's Save is ${wikiSave.bg}, not solid`)
  await shot(`wiki-edit-${scheme}`)
}
console.log(before ? 'before: screenshots taken' : `ok: ${JSON.stringify(results)}`)
await browser.close()
