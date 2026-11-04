// The browser half of tools/e2e/brand-tokens.sh (#1702).
//
//   node tools/e2e/brand-tokens.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board, card] = process.argv.slice(2)
const shots = process.env.SHOTS
const beforeCss = process.env.BEFORE_CSS
const fail = (w) => { throw new Error(w) }

const want = {
  light: { 'base-100': '#FFFFFF', 'base-content': '#10263A', primary: '#1A6E7C' },
  dark: { 'base-100': '#16304A', 'base-content': '#EAF1F3', primary: '#5FB3C1' },
}

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await ctx.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path, scheme) => {
  await page.emulateMedia({ colorScheme: scheme })
  await page.goto(base + path, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
}
const tokens = () => page.evaluate(() => {
  const s = getComputedStyle(document.documentElement)
  const v = (n) => s.getPropertyValue(`--color-${n}`).trim().toUpperCase()
  return {
    theme: document.documentElement.dataset.theme,
    'base-100': v('base-100'), 'base-content': v('base-content'), primary: v('primary'),
    meta: (document.querySelector('meta[name="theme-color"]')?.content || '').toUpperCase(),
    muted: (() => {
      const el = document.createElement('span'); el.className = 'text-base-content/60'
      document.body.appendChild(el); const c = getComputedStyle(el).color; el.remove(); return c
    })(),
  }
})

for (const scheme of ['light', 'dark']) {
  await open('/', scheme)
  const t = await tokens()
  if (t.theme !== scheme) fail(`${scheme}: data-theme is ${t.theme}`)
  for (const [k, v] of Object.entries(want[scheme])) if (t[k] !== v) fail(`${scheme} ${k}: ${t[k]}, want ${v}`)
  if (t.meta !== want[scheme]['base-100']) fail(`${scheme} theme-color: ${t.meta}`)
  if (!/ 0\.65\)$/.test(t.muted)) fail(`${scheme} muted text: ${t.muted}, want 65%`)
  console.log(`ok ${scheme}: tokens, theme-color ${t.meta}, muted ${t.muted}`)
}

// Switching the theme in the page moves theme-color with it.
await open('/', 'light')
await page.evaluate(() => {
  // What the theme buttons do: JS.dispatch("phx:set-theme") from an element
  // carrying data-phx-theme, bubbling up to theme.js's listener.
  const b = document.createElement('button'); b.dataset.phxTheme = 'dark'; document.body.appendChild(b)
  b.dispatchEvent(new CustomEvent('phx:set-theme', { bubbles: true }))
  b.remove()
})
const switched = await tokens()
if (switched.theme !== 'dark' || switched.meta !== '#16304A') fail(`after switching: ${JSON.stringify(switched)}`)
await page.evaluate(() => localStorage.removeItem('phx:theme'))
console.log('ok switching to dark moves theme-color to #16304A')

// The loading bar: start a page load the way LiveView does, and read the
// colour off the canvas topbar draws once its 300ms delay is up.
for (const [scheme, rgb] of [['light', [0x1a, 0x6e, 0x7c]], ['dark', [0x5f, 0xb3, 0xc1]]]) {
  await open(`/boards/${board}`, scheme)
  const bar = await page.evaluate(async () => {
    window.dispatchEvent(new CustomEvent('phx:page-loading-start', { detail: {} }))
    for (let i = 0; i < 100; i++) {
      await new Promise((r) => setTimeout(r, 20))
      const cv = [...document.querySelectorAll('canvas')].find((c) => c.style.position === 'fixed' && c.width > 0)
      if (!cv) continue
      const px = cv.getContext('2d').getImageData(1, 1, 1, 1).data
      if (px[3] > 200) return [...px].slice(0, 3)
    }
    return null
  })
  await page.evaluate(() => window.dispatchEvent(new CustomEvent('phx:page-loading-stop', { detail: {} })))
  if (!bar) fail(`${scheme}: no loading bar drawn`)
  if (bar.some((c, i) => Math.abs(c - rgb[i]) > 6)) fail(`${scheme} loading bar rgb(${bar}), want the primary rgb(${rgb})`)
  console.log(`ok ${scheme} loading bar is the primary: rgb(${bar})`)
}

if (shots) {
  const screens = { home: '/', board: `/boards/${board}`, card: `/boards/${board}/cards/${card}`, account: '/account' }
  const take = async (label) => {
    for (const scheme of ['light', 'dark']) for (const [name, path] of Object.entries(screens)) {
      await open(path, scheme)
      await page.waitForTimeout(150)
      await page.screenshot({ path: `${shots}/${label}-${name}-${scheme}.png` })
    }
  }
  await take('after')
  if (beforeCss) {
    const css = readFileSync(beforeCss)
    await page.route('**/assets/css/app*.css*', (r) => r.fulfill({ body: css, contentType: 'text/css' }))
    await take('before')
    await page.unroute('**/assets/css/app*.css*')
  }
  console.log(`shots in ${shots}`)
}
await browser.close()
console.log('PASS brand tokens')
