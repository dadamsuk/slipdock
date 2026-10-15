// The browser half of tools/e2e/card-column-drop.sh (#827).
//
//   node tools/e2e/card-column-drop.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1600, height: 900 } })

// By the list's header: the cards' move menus name every list too.
const column = (name) => page.locator('.kanban-column', { has: page.locator('.column-handle', { hasText: name }) }).first()
const titles = (name) => column(name).locator('.kanban-card').evaluateAll(cs => cs.map(c => c.innerText.split('\n')[0].trim()))

// Drag the card titled `title` to (x, y), in steps as a hand would.
async function drag(title, x, y) {
  const card = page.locator('.kanban-card', { hasText: title }).first()
  const from = await card.boundingBox()
  await page.mouse.move(from.x + 20, from.y + from.height / 2)
  await page.mouse.down()
  for (let i = 1; i <= 15; i++) {
    await page.mouse.move(from.x + 20 + (x - from.x - 20) * (i / 15), from.y + from.height / 2 + (y - from.y - from.height / 2) * (i / 15))
  }
  await page.waitForTimeout(200)
  await page.mouse.up()
  await page.waitForTimeout(800)
}

async function expectList(name, want) {
  for (let i = 0; i < 20; i++) {
    const got = await titles(name)
    if (JSON.stringify(got) === JSON.stringify(want)) return
    await page.waitForTimeout(250)
  }
  fail(`${name} has ${JSON.stringify(await titles(name))}, wanted ${JSON.stringify(want)}`)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await expectList('Backlog', ['Alpha', 'Bravo', 'Charlie'])

  // Alpha onto To Do's header: the bottom of To Do.
  let box = await column('To Do').boundingBox()
  await drag('Alpha', box.x + box.width / 2, box.y + 12)
  await expectList('To Do', ['Delta', 'Echo', 'Alpha'])
  await expectList('Backlog', ['Bravo', 'Charlie'])
  console.log('ok: dropped on a list header, went to its bottom')

  // Bravo onto the empty board well below In Progress.
  box = await column('In Progress').boundingBox()
  const scroll = await page.locator('#board-scroll').boundingBox()
  await drag('Bravo', box.x + box.width / 2, Math.min(box.y + box.height + 200, scroll.y + scroll.height - 10))
  await expectList('In Progress', ['Foxtrot', 'Bravo'])
  console.log('ok: dropped under a short list, went to its bottom')

  // Charlie onto its own list's header: stays where it was.
  box = await column('Backlog').boundingBox()
  await drag('Charlie', box.x + box.width / 2, box.y + 12)
  await expectList('Backlog', ['Charlie'])
  console.log('ok: dropped on its own list outside the cards, stayed put')

  // Over the cards themselves Sortable still places it: Charlie above Delta.
  const delta = await page.locator('.kanban-card', { hasText: 'Delta' }).first().boundingBox()
  await drag('Charlie', delta.x + delta.width / 2, delta.y + 4)
  await expectList('To Do', ['Charlie', 'Delta', 'Echo', 'Alpha'])
  console.log('ok: dropped among cards, went between them')
} catch (e) {
  await page.screenshot({ path: '/tmp/card-column-drop-failure.png' })
  fail(e.message + ' (screenshot: /tmp/card-column-drop-failure.png)')
} finally {
  await browser.close()
}
