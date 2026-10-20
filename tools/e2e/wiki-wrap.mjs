// The browser half of tools/e2e/wiki-wrap.sh (#1169).
//
//   node tools/e2e/wiki-wrap.mjs <login-url> <base-url> <board-id> <page-slug>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, slug] = process.argv.slice(2)
const failures = []
const fail = (why) => { console.error('FAIL: ' + why); failures.push(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})

// What sticks out past the viewport, and whether the page scrolls sideways.
const measure = (selector) => page => page.evaluate((selector) => {
  const vw = document.documentElement.clientWidth
  const root = document.querySelector(selector)
  const wide = [...root.querySelectorAll('*')]
    .filter(el => el.getBoundingClientRect().right > vw + 1)
    .map(el => `${el.tagName.toLowerCase()}.${el.className} right=${Math.round(el.getBoundingClientRect().right)}`)
  // A code block or table that scrolls sideways hides the rest of its line
  // just as surely as the page running off the screen does.
  const scrolls = [...root.querySelectorAll('pre, table')]
    .filter(el => el.scrollWidth > el.clientWidth + 1)
    .map(el => `${el.tagName.toLowerCase()} ${el.scrollWidth} > ${el.clientWidth}`)
  return { vw, pageScroll: document.documentElement.scrollWidth, wide: wide.slice(0, 8), scrolls }
}, selector)

try {
  // The sign-in link works once, so one context, resized for each width.
  const page = await (await browser.newContext()).newPage()
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  for (const [label, viewport] of [['desktop', { width: 1280, height: 900 }], ['phone', { width: 390, height: 844 }]]) {
    await page.setViewportSize(viewport)

    for (const [mode, path, selector] of [
      ['read', `/boards/${board}/wiki/${slug}`, '#wiki-body'],
      ['edit', `/boards/${board}/wiki/${slug}/edit`, '.cm-content'],
      ['edit preview', `/boards/${board}/wiki/${slug}/edit`, '.wiki-prose'],
    ]) {
      await page.goto(base + path, { waitUntil: 'networkidle' })
      await page.waitForSelector('.phx-connected')
      await page.waitForSelector(selector, { state: 'attached' })
      await page.waitForTimeout(500)
      const m = await measure(selector)(page)
      console.log(label, mode, JSON.stringify(m))
      await page.screenshot({ path: `${process.env.SHOTS || '/tmp'}/wiki-wrap-${label}-${mode.replace(' ', '-')}.png` })
      for (const what of ['pre', 'table']) {
        const el = page.locator(`${selector} ${what}`).first()
        if (await el.isVisible()) await el.screenshot({ path: `${process.env.SHOTS || '/tmp'}/wiki-wrap-${label}-${mode.replace(' ', '-')}-${what}.png` })
      }
      if (m.pageScroll > m.vw + 1) fail(`${label} ${mode}: the page scrolls sideways (${m.pageScroll} > ${m.vw})`)
      if (m.wide.length) fail(`${label} ${mode}: past the viewport: ${m.wide.join('; ')}`)
      if (m.scrolls.length) fail(`${label} ${mode}: scrolls sideways: ${m.scrolls.join('; ')}`)
    }
  }
  if (failures.length) process.exit(1)
  console.log('ok: long Markdown lines wrap within the viewport, read and edited, desktop and phone')
} finally {
  await browser.close()
}
