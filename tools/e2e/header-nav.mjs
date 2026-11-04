// The browser half of tools/e2e/header-nav.sh (#1713).
//
//   node tools/e2e/header-nav.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const fail = (w) => { throw new Error(w) }
const shot = async (loc, name) => { if (process.env.SHOTS) await loc.screenshot({ path: `${process.env.SHOTS}/${name}.png` }) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
}
const visible = (sel) => page.locator(sel).first().isVisible()
const left = async (sel) => {
  const box = await page.locator(sel).first().boundingBox()
  if (!box) fail(`${sel} not shown`)
  return box.x
}

// 1. The three places, the current one marked, on each.
for (const [path, id] of [['/', 'boards'], ['/work', 'work'], ['/wiki', 'wiki'], [`/boards/${board}`, 'boards']]) {
  await open(path)
  for (const p of ['boards', 'work', 'wiki']) {
    if (!(await visible(`#primary-nav-${p}`))) fail(`${p} link not shown on ${path}`)
  }
  const current = await page.locator('#primary-nav [aria-current=page]').count()
  if (id && !(await page.locator(`#primary-nav-${id}[aria-current=page]`).count())) fail(`${id} not marked on ${path}`)
  if (!id && current) fail(`something marked on ${path}`)
  if (path.startsWith('/boards/')) await shot(page.locator('header'), 'header-nav-board')
}

// 2. The right-hand order: search field, quick add, heart, bell, avatar.
await open('/')
await shot(page.locator('header'), 'header-nav-lg')
const order = ['#search-field', '#quick-add-open', '#favourites-link', '#alerts-bar > button', '#account-menu']
const xs = []
for (const sel of order) xs.push(await left(sel))
for (let i = 1; i < xs.length; i++) if (xs[i] <= xs[i - 1]) fail(`${order[i]} is not right of ${order[i - 1]}: ${xs}`)
for (const sel of ['#quick-note-open', '#search-link', '#ask-link', '#waiting-link']) {
  if (await visible(sel)) fail(`${sel} still shown from lg up`)
}
if (!(await page.locator('#search-field .hero-magnifying-glass').count())) fail('search glyph is not a magnifying glass')

// 3. Every visible icon button says what it is and its key.
const unnamed = await page.$$eval('header .btn-square, header #search-field, #alerts-bar > button', (els) =>
  els.filter((e) => e.offsetParent !== null && e.closest('#header-links') === null)
     .filter((e) => !/\(.+\)$/.test(e.getAttribute('title') || '') || e.getAttribute('title') !== e.getAttribute('aria-label'))
     .map((e) => e.outerHTML.slice(0, 120)))
if (unnamed.length) fail(`unnamed: ${unnamed.join('\n')}`)

// 4. The bell: one alert and one wait make 2, and the panel leads with the wait.
const total = (await page.locator('#alerts-total').innerText()).trim()
if (total !== '2') fail(`bell badge says ${total}, not 2`)
await page.click('#alerts-bar > button')
await page.locator('#alerts-waiting').waitFor()
await shot(page.locator('#alerts-panel'), 'header-nav-alerts')
await page.keyboard.press('Escape')
await page.locator('#alerts-panel').waitFor({ state: 'detached' })

// 5. Quick note from inside quick add: two clicks.
await page.click('#quick-add-open')
await page.locator('#quick-add-note').waitFor()
await shot(page.locator('#quick-add-panel'), 'header-nav-quick-add')
await page.click('#quick-add-note')
await page.locator('#quick-note-panel').waitFor()
if (await page.locator('#quick-add-panel').count()) fail('quick add stayed open under the quick note')

// 6. The keys: Shift-Alt-F to Favourites, Shift-Alt-A to Ask.
await open('/')
await page.keyboard.press('Shift+Alt+F')
await page.waitForURL(`${base}/favourites`)
await page.waitForSelector('.phx-connected')
await page.keyboard.press('Shift+Alt+A')
await page.waitForURL(`${base}/ask`)

// 7. A tablet keeps its icons, and has no room for the links.
await page.setViewportSize({ width: 900, height: 900 })
await open('/')
if (await visible('#primary-nav')) fail('primary nav shown on a tablet')
for (const sel of ['#search-link', '#ask-link', '#favourites-link', '#quick-note-open']) {
  if (!(await visible(sel))) fail(`${sel} gone on a tablet`)
}
if (await visible('#search-field')) fail('search field shown on a tablet')
await shot(page.locator('header'), 'header-nav-tablet')

console.log('ok: header nav, order, tooltips, bell, quick note, keys, tablet')
await browser.close()
