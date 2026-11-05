// The browser half of tools/e2e/admin-nav.sh: the Admin area in the settings
// layout (#1738). Every admin page is under one "Admin" h1 with the Admin
// nav beside it from md up (a picker on a phone), the current page marked
// and its label heading the content, the running build in the nav's footer,
// and no tablist of its own. Configuration's forms sit in the narrow column,
// the tables and dashboards in the wide one. The People panel still opens
// and closes, and an ordinary person is turned away.
//
//   node tools/e2e/admin-nav.mjs <admin-login-url> <base-url> <ordinary-login-url>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, ordinaryUrl] = process.argv.slice(2)
const shots = process.env.SHOTS
const before = process.env.BEFORE === '1'
const fail = (w) => { throw new Error(w) }
const ok = (w) => console.log(`ok: ${w}`)

// [path, label, content width]
const sections = [
  ['/users', 'People', 'wide'],
  ['/users/signups', 'Sign-ups', 'wide'],
  ['/overview', 'Overview', 'wide'],
  ['/config', 'Server', 'narrow'],
  ['/config/mail', 'Email', 'narrow'],
  ['/config/meetings', 'Meetings', 'narrow'],
  ['/config/ai', 'AI', 'narrow'],
  ['/admin/tools', 'Tools', 'wide'],
]

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const signIn = async (url) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  const page = await context.newPage()
  await page.goto(url, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  return page
}
const page = await signIn(loginUrl)

const open = async (path, p = page) => {
  await p.goto(`${base}${path}`, { waitUntil: 'load' })
  await p.waitForSelector('.phx-connected')
  await p.waitForTimeout(200)
}
const snap = async (name) => {
  if (shots) await page.screenshot({ path: `${shots}/${before ? 'before' : 'after'}-${name}.png`, fullPage: false })
}

if (before) {
  for (const [w, h] of [[1440, 900], [1280, 800]]) {
    await page.setViewportSize({ width: w, height: h })
    for (const [path, name] of [['/users', 'people'], ['/overview', 'overview'], ['/config', 'server'], ['/config/mail', 'email'], ['/admin/tools', 'tools']]) {
      await open(path)
      await snap(`admin-${name}-${w}`)
    }
  }
  await page.setViewportSize({ width: 390, height: 844 })
  await open('/config')
  await snap('admin-server-390')
  await browser.close()
  process.exit(0)
}

// Each link in a list: its href, its label, whether it is current, and
// whether it sits wholly inside the viewport and its nav.
const listed = (sel) => page.evaluate((sel) => {
  const nav = document.querySelector(sel)
  if (!nav) return { error: `no ${sel}` }
  const box = nav.getBoundingClientRect()
  const links = [...nav.querySelectorAll('a')].map((a) => {
    const r = a.getBoundingClientRect()
    const label = a.querySelector('span.min-w-0')
    return {
      href: a.getAttribute('href'), text: label ? label.innerText.trim() : a.innerText.trim(),
      current: a.getAttribute('aria-current'),
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

// 1. From md up: the Admin nav on every admin page, at 1440 and 1280.
for (const [w, h] of [[1440, 900], [1280, 800]]) {
  await page.setViewportSize({ width: w, height: h })
  for (const [path, label, width] of sections) {
    await open(path)
    const where = `${w} ${path}`
    if (!(await page.locator('#admin-nav').isVisible())) fail(`${where}: no Admin nav`)
    if (await page.locator('#admin-picker').isVisible()) fail(`${where}: the phone picker shows`)
    checkList(where, await listed('#admin-nav'), path)
    if ((await page.locator('h1').innerText()).trim() !== 'Admin') fail(`${where}: the h1 isn't Admin`)
    const title = (await page.locator('#admin-content [data-role=settings-section-title]').innerText()).trim()
    if (title !== label) fail(`${where}: the content is headed "${title}", not "${label}"`)
    if (await page.locator('[data-page-width=full]').count() !== 1) fail(`${where}: not one full-width page`)
    if ((await page.locator('#admin-content').getAttribute('data-content-width')) !== width) fail(`${where}: content isn't ${width}`)
    const contentWidth = await page.locator('#admin-content').evaluate((e) => e.getBoundingClientRect().width)
    if (width === 'narrow' && contentWidth > 673) fail(`${where}: the narrow column is ${contentWidth}px`)
    if (width === 'wide' && contentWidth <= 700) fail(`${where}: the wide column is only ${contentWidth}px`)
    if (await page.locator('[role=tablist], .tabs-box').count()) fail(`${where}: a tablist is left`)
    const build = page.locator('#admin-nav [data-role=settings-nav-footer] [data-role=build-info]')
    if (!(await build.isVisible())) fail(`${where}: no build strip in the nav's footer`)
    const text = await build.innerText()
    for (const word of ['Running build', 'Built', 'Commit', 'Version']) if (!text.includes(word)) fail(`${where}: the build strip lacks ${word}`)
    // The strip fits its column: nothing pokes out sideways.
    const spill = await build.evaluate((e) => e.scrollWidth > e.clientWidth + 1)
    if (spill) fail(`${where}: the build strip overflows the nav`)
  }
  const badge = page.locator('#admin-nav a[href="/users/signups"] [data-role=settings-badge]')
  if ((await badge.innerText()).trim() !== '1') fail(`${w}: Sign-ups doesn't show the one waiting`)
  for (const [path, name] of [['/users', 'people'], ['/overview', 'overview'], ['/config', 'server'], ['/config/mail', 'email'], ['/admin/tools', 'tools']]) {
    await open(path)
    await snap(`admin-${name}-${w}`)
  }
  ok(`${w}: all ${sections.length} admin pages under Admin, nav marked and headed, build in the footer, no tablist, widths right`)
}

// 2. A nav entry is a fresh mount at its own URL.
await page.setViewportSize({ width: 1440, height: 900 })
await open('/config')
await Promise.all([page.waitForURL(`${base}/config/ai`), page.locator('#admin-nav a[href="/config/ai"]').click()])
await page.waitForSelector('#admin-nav a[href="/config/ai"][aria-current=page]')
if (!(await page.locator('#ai-models').isVisible())) fail('clicking AI did not show the AI models')
if (await page.locator('#admin-mail-form').count()) fail('Email is still there beside AI')
ok('a nav entry loads its section at its own URL, and only that section')

// 3. People's person panel (#1739) still opens from a row and closes.
await open('/users')
await page.locator('#people a[id^=manage-]').first().click()
await page.waitForSelector('#person-panel', { state: 'visible' })
if (!page.url().includes('/users?user=')) fail(`the panel's URL is ${page.url()}`)
if (!(await page.locator('#admin-nav a[href="/users"][aria-current=page]').count())) fail('People is not current with the panel open')
await snap('admin-people-panel-1440')
await page.keyboard.press('Escape')
await page.waitForSelector('#person-panel', { state: 'detached' })
if (page.url() !== `${base}/users`) fail(`closing the panel left ${page.url()}`)
ok('the People panel opens at ?user= inside the Admin area and closes back to /users')

// 4. A phone: no side nav; the picker names the page, lists every entry, and
//    carries the build strip.
await page.setViewportSize({ width: 390, height: 844 })
await open('/config/meetings')
if (await page.locator('#admin-nav').isVisible()) fail('390: the side nav shows on a phone')
const picker = page.locator('#admin-picker')
if (!(await picker.isVisible())) fail('390: no section picker')
const summary = (await picker.locator('summary').innerText()).replace(/\s+/g, ' ').trim()
if (!summary.includes('Meetings')) fail(`390: the picker says "${summary}"`)
await snap('admin-server-390')
await picker.locator('summary').click()
checkList('390 picker', await listed('#admin-picker nav'), '/config/meetings')
if (!(await picker.locator('[data-role=build-info]').isVisible())) fail('390: no build strip in the picker')
await snap('admin-picker-390-open')
await Promise.all([page.waitForURL(`${base}/admin/tools`), picker.locator('a[href="/admin/tools"]').click()])
await page.waitForSelector('#admin-picker a[href="/admin/tools"][aria-current=page]', { state: 'attached' })
if ((await page.locator('#admin-content [data-role=settings-section-title]').innerText()).trim() !== 'Tools')
  fail('390: the picker did not reach Tools')
ok('390: the picker names the page, lists every entry with the build strip, and goes to Tools')

// 5. Somebody who isn't an admin is turned away from every admin page.
const other = await signIn(ordinaryUrl)
for (const [path] of sections) {
  await other.goto(`${base}${path}`, { waitUntil: 'load' })
  await other.waitForTimeout(200)
  const at = new URL(other.url()).pathname
  if (at === path) fail(`an ordinary person reached ${path}`)
  if (await other.locator('#admin-nav').count()) fail(`an ordinary person sees the Admin nav at ${path}`)
}
ok('an ordinary person is refused every admin page')

await browser.close()
console.log('admin-nav: all checks passed')
