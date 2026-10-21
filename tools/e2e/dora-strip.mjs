// The browser half of tools/e2e/dora-strip.sh (#1184).
//
//   node tools/e2e/dora-strip.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board] = process.argv.slice(2)
const failures = []
const fail = (why) => { console.error('FAIL: ' + why); failures.push(why) }
const shots = process.env.SHOTS || '/tmp'

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})

try {
  const page = await (await browser.newContext()).newPage()
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  for (const [label, viewport] of [['desktop', { width: 1280, height: 900 }], ['phone', { width: 390, height: 844 }]]) {
    await page.setViewportSize(viewport)
    for (const theme of ['light', 'dark']) {
      await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
      await page.waitForSelector('.phx-connected')
      await page.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      await page.waitForTimeout(300)
      const strip = page.locator('#board-dora')
      await strip.screenshot({ path: `${shots}/dora-strip-${label}-${theme}.png` })

      // Each banded metric has a pill whose background is a colour of its own.
      const pills = await strip.locator('.badge').evaluateAll(els => els.map(el => ({
        band: el.textContent.trim(),
        bg: getComputedStyle(el).backgroundColor,
        fg: getComputedStyle(el).color,
      })))
      console.log(label, theme, JSON.stringify(pills))
      const bands = pills.map(p => p.band).sort().join(',')
      if (bands !== 'elite,high,low,medium') fail(`${label} ${theme}: bands were ${bands}`)
      if (new Set(pills.map(p => p.bg)).size !== pills.length) fail(`${label} ${theme}: pills share a colour`)
      if (pills.some(p => /rgba\(0, 0, 0, 0\)|transparent/.test(p.bg))) fail(`${label} ${theme}: a pill has no background`)

      const { vw, sw } = await page.evaluate(() => ({ vw: document.documentElement.clientWidth, sw: document.documentElement.scrollWidth }))
      if (sw > vw + 1) fail(`${label} ${theme}: the page scrolls sideways (${sw} > ${vw})`)
    }
  }
} finally {
  await browser.close()
}

if (failures.length) { console.error(`${failures.length} failure(s)`); process.exit(1) }
console.log('ok')
