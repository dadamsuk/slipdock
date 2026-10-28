// The browser half of tools/e2e/home-reorder.sh: Reorder, a drag from the
// middle of a tile, Done, and a press that opens the board again.
//
//   node tools/e2e/home-reorder.mjs <login-url> <base-url> <kb-id> <hunt-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, hunt] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const shots = process.env.SHOTS

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

const order = () => page.$$eval('#boards > [data-id]', (els) => els.map((e) => e.dataset.id))

const drag = async (from, to) => {
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2)
  await page.mouse.down()
  for (let i = 1; i <= 20; i++) {
    await page.mouse.move(
      from.x + from.width / 2 + (to.x + 20 - from.x - from.width / 2) * (i / 20),
      from.y + from.height / 2 + (to.y + 20 - from.y - from.height / 2) * (i / 20),
    )
  }
  await page.mouse.up()
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  const before = await order()
  if (before.indexOf(kb) > before.indexOf(hunt)) fail('Keystone should start first: ' + before)

  await page.click('#reorder-boards')
  await page.waitForSelector('#reorder-hint')
  const style = await page.$eval(`#board-${hunt}`, (e) => getComputedStyle(e).outlineStyle)
  if (style !== 'dashed') fail('the tile is not outlined: ' + style)
  if (shots) await page.screenshot({ path: `${shots}/home-reorder.png`, fullPage: true })

  // From the middle of the tile, where its link is: a drag, not a visit.
  await drag(await page.locator(`#board-${hunt}`).boundingBox(), await page.locator(`#board-${kb}`).boundingBox())
  await page.waitForFunction((id) => document.querySelector('#boards > [data-id]').dataset.id === id, hunt)
  if (new URL(page.url()).pathname !== '/') fail('the drag opened ' + page.url())

  // A plain click in the mode opens nothing either.
  await page.click(`#board-${kb}`)
  await page.waitForTimeout(300)
  if (new URL(page.url()).pathname !== '/') fail('a click opened ' + page.url())

  await page.click('#reorder-hint button')
  await page.waitForSelector('#reorder-hint', { state: 'detached' })
  // Out of the mode a drag from the middle moves nothing: the handle is back.
  await drag(await page.locator(`#board-${kb}`).boundingBox(), await page.locator(`#board-${hunt}`).boundingBox())
  await page.waitForTimeout(500)
  const kept = await page.$$eval('#boards > [data-id]', (els) => els.map((e) => e.dataset.id))
  if (kept[0] !== hunt) fail('a drag outside the mode moved: ' + kept)

  await page.goto(`${base}/`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await Promise.all([page.waitForURL((u) => u.pathname !== '/'), page.click(`#board-${hunt} a >> nth=0`)])

  console.log('ok: Reorder drags whole tiles without opening them, and Done puts the links back')
} finally {
  await browser.close()
}
