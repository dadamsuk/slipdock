// The browser half of tools/e2e/mobile-dock-drag.sh (#1130).
//
//   node tools/e2e/mobile-dock-drag.mjs <login-url> <base-url> <board-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium, webkit, devices } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = process.env.BROWSER === 'webkit'
  ? await webkit.launch()
  : await chromium.launch({
      executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
      args: ['--no-sandbox'],
    })
const page = await (await browser.newContext({ ...devices['iPhone 13'] })).newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }
const vp = page.viewportSize()

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

const fab = () => page.locator('#mobile-fab').boundingBox()
const bar = (attr) => page.getAttribute('#mobile-bar', attr)
const onScreen = (b) => b && b.x >= 0 && b.y >= 0 && b.x + b.width <= vp.width && b.y + b.height <= vp.height

// A finger drag, as touch events through the DevTools protocol in Chromium
// (so touch-action and pointer capture are what a phone has), with the
// mouse elsewhere.
async function drag(to) {
  const b = await fab()
  const from = { x: b.x + b.width / 2, y: b.y + b.height / 2 }
  const steps = 12
  if (process.env.BROWSER === 'webkit') {
    await page.mouse.move(from.x, from.y)
    await page.mouse.down()
    for (let i = 1; i <= steps; i++) await page.mouse.move(from.x + (to.x - from.x) * i / steps, from.y + (to.y - from.y) * i / steps)
    await page.mouse.up()
  } else {
    const cdp = await page.context().newCDPSession(page)
    const touch = (type, p) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: p ? [{ x: p.x, y: p.y }] : [] })
    await touch('touchStart', from)
    for (let i = 1; i <= steps; i++) {
      await touch('touchMove', { x: from.x + (to.x - from.x) * i / steps, y: from.y + (to.y - from.y) * i / steps })
      await page.waitForTimeout(16)
    }
    await touch('touchEnd')
  }
  await page.waitForTimeout(500)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await open(`/boards/${board}`)
  await page.evaluate(() => localStorage.removeItem('slipdock.dock'))
  await open(`/boards/${board}`)

  // Where it starts: the bottom-left corner, and a tap opens and folds the row.
  const start = await fab()
  if (!(start.x < 40 && start.y > vp.height / 2)) fail(`it did not start bottom-left: ${JSON.stringify(start)}`)
  await page.tap('#mobile-fab')
  await page.waitForTimeout(400)
  if (!(await page.locator('#mobile-dock').isVisible())) fail('a tap did not open the row')
  await page.tap('#mobile-fab')
  await page.waitForTimeout(400)

  // Drag it to the upper right.
  await drag({ x: vp.width - 80, y: 160 })
  await shot('dragged')
  if (await page.locator('#mobile-dock').isVisible()) fail('the drag opened the row as a tap would')
  if ((await bar('data-side')) !== 'right' || (await bar('data-edge')) !== 'top') fail(`it did not settle top-right: side ${await bar('data-side')} edge ${await bar('data-edge')}`)
  const moved = await fab()
  if (Math.abs(vp.width - (moved.x + moved.width) - 12) > 2) fail(`it is not against the right edge: ${JSON.stringify(moved)}`)
  if (Math.abs(moved.y + moved.height / 2 - 160) > 4) fail(`it is not at the height it was dropped: ${JSON.stringify(moved)}`)
  console.log('ok: dragged to the upper right and settled against the edge', JSON.stringify(moved))

  // From there a tap still opens it; the row and the Menu are on screen.
  await page.tap('#mobile-fab')
  await page.waitForTimeout(400)
  const dock = await page.locator('#mobile-dock').boundingBox()
  if (!onScreen(dock)) fail(`the row runs off the screen: ${JSON.stringify(dock)}`)
  if (dock.x + dock.width > moved.x) fail('the row did not open leftwards from the button')
  await page.tap('#mobile-menu-button')
  await page.waitForTimeout(400)
  await shot('menu-top-right')
  const menu = await page.locator('#mobile-menu-list').boundingBox()
  if (!(await page.locator('#mobile-menu-list').isVisible()) || !onScreen(menu)) fail(`the Menu is not on screen: ${JSON.stringify(menu)}`)
  if (menu.y < dock.y) fail('in the top half the Menu should open downwards')
  console.log('ok: the row and the Menu open on screen from the top right', JSON.stringify(menu))

  // A LiveView navigation and a reload keep it where it was put.
  await page.locator('#mobile-menu-list a', { hasText: 'Wiki' }).first().tap()
  await page.waitForURL(/\/wiki/)
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(300)
  if ((await bar('data-side')) !== 'right') fail('it went back to the corner after navigating')
  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const after = await fab()
  if (Math.abs(after.y - moved.y) > 2 || (await bar('data-side')) !== 'right') fail(`it did not keep its place over a reload: ${JSON.stringify(after)}`)
  console.log('ok: kept its place over a navigation and a reload')

  // And back to the bottom left, where the Menu opens upwards again.
  await drag({ x: 40, y: vp.height - 120 })
  if ((await bar('data-side')) !== 'left' || (await bar('data-edge')) !== 'bottom') fail('it did not settle back bottom-left')
  await page.tap('#mobile-fab')
  await page.waitForTimeout(400)
  await page.tap('#mobile-menu-button')
  await page.waitForTimeout(400)
  const low = await page.locator('#mobile-menu-list').boundingBox()
  const lowFab = await fab()
  if (!onScreen(low) || low.y + low.height > lowFab.y) fail(`the Menu should open upwards on screen: ${JSON.stringify(low)}`)
  await shot('menu-bottom-left')
  console.log('ok: dragged back to the bottom left; the Menu opens upwards')
} catch (e) {
  await shot('error')
  fail(e.message)
} finally {
  await browser.close()
}
