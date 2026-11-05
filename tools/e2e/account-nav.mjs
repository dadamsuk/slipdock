// The browser half of tools/e2e/account-nav.sh: Account in the settings
// layout (#1737). From md up a side nav lists every section, none clipped
// and nothing scrolling sideways; on a phone a picker opens onto the same
// list. The current section is aria-current and its label heads the content,
// and following a link loads that section (its own mount, its own URL).
//
//   node tools/e2e/account-nav.mjs <login-url> <base-url>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base] = process.argv.slice(2)
const shots = process.env.SHOTS
const before = process.env.BEFORE === '1'
const fail = (w) => { throw new Error(w) }
const ok = (w) => console.log(`ok: ${w}`)

const sections = [
  ['/account', 'Profile'],
  ['/account/settings', 'Preferences'],
  ['/account/sign-in', 'Sign-in & passkeys'],
  ['/account/tokens', 'API tokens'],
  ['/account/agent', 'Set up an agent'],
  ['/account/data', 'Import & export'],
  ['/account/voiceprint', 'Voiceprint'],
  ['/account/email-log', 'Email log'],
]

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(200)
}
const snap = async (name) => {
  if (shots) await page.screenshot({ path: `${shots}/${before ? 'before' : 'after'}-${name}.png` })
}

if (before) {
  for (const [w, h] of [[1440, 900], [1280, 800], [390, 844]]) {
    await page.setViewportSize({ width: w, height: h })
    await open('/account')
    await snap(`account-${w}`)
  }
  await browser.close()
  process.exit(0)
}

// Each link in a list: its href, its text, and whether it sits wholly inside
// the viewport and its own nav (nothing clipped, nothing scrolled away).
const listed = (sel) => page.evaluate((sel) => {
  const nav = document.querySelector(sel)
  if (!nav) return { error: `no ${sel}` }
  const box = nav.getBoundingClientRect()
  const links = [...nav.querySelectorAll('a')].map((a) => {
    const r = a.getBoundingClientRect()
    const label = a.querySelector('span:last-child')
    return {
      href: a.getAttribute('href'), text: a.innerText.trim(), current: a.getAttribute('aria-current'),
      inside: r.width > 0 && r.left >= box.left - 0.5 && r.right <= box.right + 0.5 && r.right <= innerWidth,
      clipped: label ? label.scrollWidth > label.clientWidth + 1 : false,
    }
  })
  const scroller = document.querySelector('main .kanban-scroll') || document.documentElement
  return {
    links, navScrolls: nav.scrollWidth > nav.clientWidth + 1,
    pageScrolls: scroller.scrollWidth > scroller.clientWidth + 1 || document.documentElement.scrollWidth > innerWidth + 1,
  }
}, sel)

const checkList = (where, got, current) => {
  if (got.error) fail(`${where}: ${got.error}`)
  const hrefs = got.links.map((l) => l.href).join(' ')
  if (hrefs !== sections.map((s) => s[0]).join(' ')) fail(`${where}: lists ${hrefs}`)
  for (const [i, l] of got.links.entries()) {
    if (l.text !== sections[i][1]) fail(`${where}: "${l.text}" where "${sections[i][1]}" should be`)
    if (!l.inside) fail(`${where}: ${l.text} is outside the nav or the viewport`)
    if (l.clipped) fail(`${where}: ${l.text} is clipped`)
    if ((l.href === current) !== (l.current === 'page')) fail(`${where}: aria-current is wrong on ${l.text}`)
  }
  if (got.navScrolls) fail(`${where}: the nav scrolls sideways`)
  if (got.pageScrolls) fail(`${where}: the page scrolls sideways`)
}

// 1. From md up: the side nav, at 1440 and 1280, on every section.
for (const [w, h] of [[1440, 900], [1280, 800]]) {
  await page.setViewportSize({ width: w, height: h })
  for (const [path, label] of sections) {
    await open(path)
    if (!(await page.locator('#account-nav').isVisible())) fail(`${w} ${path}: no side nav`)
    if (await page.locator('#account-picker').isVisible()) fail(`${w} ${path}: the phone picker shows`)
    checkList(`${w} ${path}`, await listed('#account-nav'), path)
    const title = (await page.locator('#account-content [data-role=settings-section-title]').innerText()).trim()
    if (title !== label) fail(`${w} ${path}: the content is headed "${title}", not "${label}"`)
    if ((await page.locator('h1').innerText()).trim() !== 'Account') fail(`${w} ${path}: the h1 isn't Account`)
  }
  await open('/account')
  await snap(`account-${w}`)
  ok(`${w}: all ${sections.length} sections in the side nav, none clipped, no sideways scroll, each marked and headed`)
}

// 2. Following a link is a fresh mount at the section's own URL.
await page.setViewportSize({ width: 1440, height: 900 })
await open('/account')
await Promise.all([
  page.waitForURL(`${base}/account/tokens`),
  page.locator('#account-nav a[href="/account/tokens"]').click(),
])
await page.waitForSelector('#account-nav a[href="/account/tokens"][aria-current=page]')
if ((await page.locator('#account-content [data-role=settings-section-title]').innerText()).trim() !== 'API tokens')
  fail('clicking API tokens did not show API tokens')
if (!(await page.locator('#account-content').innerText()).includes('slipdock auth')) fail('the tokens section is not there')
if (await page.locator('#profile-form').count() !== 0) fail('Profile is still there beside API tokens')
await snap('account-tokens-1440')
ok('a nav link loads its section at its own URL, and only that section')

// 3. A phone: no side nav; the picker names the section and reaches every one.
await page.setViewportSize({ width: 390, height: 844 })
await open('/account/data')
if (await page.locator('#account-nav').isVisible()) fail('390: the side nav shows on a phone')
const picker = page.locator('#account-picker')
if (!(await picker.isVisible())) fail('390: no section picker')
const summary = (await picker.locator('summary').innerText()).replace(/\s+/g, ' ').trim()
if (!summary.includes('Import & export')) fail(`390: the picker says "${summary}"`)
await snap('account-390')
await picker.locator('summary').click()
checkList('390 picker', await listed('#account-picker nav'), '/account/data')
await snap('account-390-open')
await Promise.all([
  page.waitForURL(`${base}/account/email-log`),
  picker.locator('a[href="/account/email-log"]').click(),
])
// A fresh mount: the picker is closed again, naming the new section.
await page.waitForSelector('#account-picker a[href="/account/email-log"][aria-current=page]', { state: 'attached' })
if (await page.locator('#account-picker').getAttribute('open') !== null) fail('390: the picker stayed open after going')
if ((await page.locator('#account-content [data-role=settings-section-title]').innerText()).trim() !== 'Email log')
  fail('390: the picker did not reach Email log')
ok('390: the picker names the section, lists all of them in reach, and goes to the last')

await browser.close()
console.log('account-nav: all checks passed')
