// The browser half of tools/e2e/visualise.sh (#1185).
//
//   node tools/e2e/visualise.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board] = process.argv.slice(2)
const failures = []
const fail = (why) => { console.error('FAIL: ' + why); failures.push(why) }
const shots = process.env.SHOTS || '/tmp'
const sections = ['#pulse', '#flow', '#chart-cfd', '#chart-velocity', '#chart-burndown', '#chart-cycle', '#aging']
  .concat((process.env.SECTIONS || '').split(',').filter(Boolean))

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})

try {
  const page = await (await browser.newContext()).newPage()
  // LiveView's own "not connected" while a page is being left is not ours.
  page.on('pageerror', (e) => { if (!/not connected/.test(e.message)) fail('page error: ' + e.message) })
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // Reached from the board's view menu.
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('#view-menu [role=button]').click()
  await page.locator(`#view-menu a[href="/boards/${board}/visualise"]`).click()
  await page.waitForURL(`**/boards/${board}/visualise`)
  await page.waitForSelector('#visualise')

  // The window switch puts the choice in the URL and redraws.
  await page.waitForSelector('.phx-connected')
  await page.locator('#window-90').click()
  await page.waitForURL(`**/visualise?days=90`)
  if ((await page.locator('#window-90').getAttribute('aria-pressed')) !== 'true') fail('90 days not pressed')
  if (!(await page.locator('#trends').textContent()).includes('Last 90 days')) fail('trends did not follow the switch')

  for (const [label, viewport] of [['desktop', { width: 1440, height: 900 }], ['phone', { width: 390, height: 844 }]]) {
    await page.setViewportSize(viewport)
    for (const theme of ['light', 'dark']) {
      await page.goto(`${base}/boards/${board}/visualise?days=30`, { waitUntil: 'networkidle' })
      await page.waitForSelector('.phx-connected')
      await page.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      await page.waitForTimeout(300)
      // The page scrolls inside its shell: grow the window to the whole of it for the picture.
      const tall = await page.evaluate(() => document.querySelector('#visualise').scrollHeight)
      await page.setViewportSize({ width: viewport.width, height: tall + 200 })
      await page.locator('#visualise').screenshot({ path: `${shots}/visualise-${label}-${theme}.png` })
      await page.setViewportSize(viewport)

      for (const s of sections) {
        if (!(await page.locator(s).count())) fail(`${label} ${theme}: ${s} missing`)
      }
      for (const c of ['#chart-cfd', '#chart-velocity', '#chart-burndown', '#chart-cycle']) {
        if (!(await page.locator(`${c} svg[role=img]`).count())) fail(`${label} ${theme}: ${c} drew no chart`)
      }

      const { vw, sw } = await page.evaluate(() => {
        const el = document.querySelector('#visualise').closest('.kanban-scroll')
        return { vw: el.clientWidth, sw: el.scrollWidth }
      })
      if (sw > vw + 1) fail(`${label} ${theme}: the page scrolls sideways (${sw} > ${vw})`)
    }
  }
} finally {
  await browser.close()
}

if (failures.length) { console.error(`${failures.length} failure(s)`); process.exit(1) }
console.log('ok')
