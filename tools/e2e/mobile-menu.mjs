// The browser half of tools/e2e/mobile-menu.sh (#1130).
//
//   node tools/e2e/mobile-menu.mjs <login-url> <base-url> <board-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium, webkit, devices } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

// BROWSER=webkit runs it in Safari's engine, where phones are most at risk.
const browser = process.env.BROWSER === 'webkit'
  ? await webkit.launch()
  : await chromium.launch({
      executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
      args: ['--no-sandbox'],
    })
const page = await (await browser.newContext({ ...devices['iPhone 13'] })).newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  for (const path of ['/', `/boards/${board}`]) {
    await open(path)
    await page.tap('#mobile-fab')
    await page.waitForSelector('#mobile-dock', { state: 'visible' })
    await page.waitForTimeout(400)
    await page.tap('#mobile-menu-button')
    await page.waitForTimeout(400)
    const menu = page.locator('#mobile-menu-list')
    await shot(`menu${path.replaceAll('/', '-')}`)
    const box = await menu.boundingBox()
    const vp = page.viewportSize()
    console.log(path, 'menu box', JSON.stringify(box), 'viewport', JSON.stringify(vp))
    if (!(await menu.isVisible())) fail(`${path}: the menu did not open`)
    if (!box || box.y < 0 || box.x < 0 || box.x + box.width > vp.width) fail(`${path}: the menu is off screen`)
    // The menu's own entries can be tapped: Boards is the topmost element at its centre.
    const link = page.locator('#mobile-menu a', { hasText: 'Wiki' }).first()
    const lb = await link.boundingBox()
    const hit = await page.evaluate(([x, y]) => {
      const el = document.elementFromPoint(x, y)
      return el && (el.closest('#mobile-menu') ? 'menu' : el.outerHTML.slice(0, 120))
    }, [lb.x + lb.width / 2, lb.y + lb.height / 2])
    if (hit !== 'menu') fail(`${path}: something covers the menu: ${hit}`)
    // The bottom of a long menu scrolls into reach, and is not covered either.
    const last = page.locator('#mobile-menu-list a[href="/logout"]')
    await last.scrollIntoViewIfNeeded()
    const sb = await last.boundingBox()
    if (!sb || sb.y < 0 || sb.y + sb.height > vp.height) fail(`${path}: Sign out is out of reach`)
    const lastHit = await page.evaluate(([x, y]) => !!document.elementFromPoint(x, y)?.closest('#mobile-menu-list'), [sb.x + sb.width / 2, sb.y + sb.height / 2])
    if (!lastHit) fail(`${path}: something covers Sign out`)
    await page.locator('#mobile-menu-list').evaluate((el) => { el.scrollTop = 0 })

    // Menu again shuts it; folding the row and opening it again finds it shut.
    await page.tap('#mobile-menu-button')
    await page.waitForTimeout(300)
    if (await menu.isVisible()) fail(`${path}: a second tap left the menu open (aria-expanded ${await page.getAttribute('#mobile-menu-button', 'aria-expanded')})`)
    await page.tap('#mobile-menu-button')
    await page.waitForTimeout(300)
    if (!(await menu.isVisible())) fail(`${path}: a third tap did not open it`)
    await page.tap('#mobile-fab')
    await page.waitForTimeout(400)
    await page.tap('#mobile-fab')
    await page.waitForTimeout(400)
    if (await menu.isVisible()) fail(`${path}: the menu came back open with the row`)
    if ((await page.getAttribute('#mobile-menu-button', 'aria-expanded')) !== 'false') fail(`${path}: aria-expanded stayed true`)
    await page.tap('#mobile-menu-button')
    await page.waitForTimeout(200)

    await link.tap()
    await page.waitForURL(/\/wiki/)
    console.log(`ok: ${path}: the menu opens on screen and its entries can be tapped`)
  }
} catch (e) {
  await shot('error')
  fail(e.message)
} finally {
  await browser.close()
}
