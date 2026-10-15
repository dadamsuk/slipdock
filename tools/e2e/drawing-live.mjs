// The browser half of tools/e2e/drawing-live.sh (#824, #825): two people, one drawing.
//
//   node tools/e2e/drawing-live.mjs <owner-login> <friend-login> <base-url> <page-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [ownerLogin, friendLogin, base, pageId] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})

async function person(loginUrl) {
  const context = await browser.newContext({ viewport: { width: 1300, height: 850 } })
  const page = await context.newPage()
  page.on('pageerror', (e) => console.log('page error:', e.stack))
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  return page
}

async function open(page) {
  await page.goto(`${base}/drawings/page/${pageId}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#drawing-editor[data-shapes]', { timeout: 20000 })
    .catch(() => fail('the editor did not open'))
}

const shapes = (page) => page.locator('#drawing-editor').getAttribute('data-shapes').then(Number)

async function waitShapes(page, n, who) {
  for (let i = 0; i < 50; i++) {
    if ((await shapes(page)) === n) return
    await page.waitForTimeout(200)
  }
  fail(`${who} sees ${await shapes(page)} shapes, not ${n}`)
}

async function rectangle(page, x, y) {
  const canvas = page.locator('canvas.interactive')
  const box = await canvas.boundingBox()
  // Excalidraw takes its shortcuts only while it has the focus.
  await page.mouse.click(box.x + 40, box.y + box.height - 120)
  await page.keyboard.press('r')
  await page.mouse.move(box.x + x, box.y + y)
  await page.mouse.down()
  await page.mouse.move(box.x + x + 120, box.y + y + 80, { steps: 8 })
  await page.mouse.up()
  await page.keyboard.press('Escape')
}

try {
  const owner = await person(ownerLogin)
  const friend = await person(friendLogin)
  await open(owner)
  await open(friend)

  if (await owner.locator('#drawing-save').count()) fail('there is still a Save button')
  console.log('ok: both have the drawing open, and there is no Save button')

  // Who is here: both avatars in each header, and the friend's cursor on the
  // owner's canvas once the friend moves.
  for (const [page, who] of [[owner, 'the owner'], [friend, 'the friend']]) {
    await page.waitForFunction(() => document.querySelectorAll('#drawing-people [data-person]').length === 2, null, { timeout: 5000 })
      .catch(() => fail(`${who} does not see two people in the header`))
  }
  console.log('ok: each header shows both people')

  const fbox = await friend.locator('canvas.interactive').boundingBox()
  for (let i = 0; i < 5; i++) {
    await friend.mouse.move(fbox.x + 600 + i * 10, fbox.y + 400)
    await friend.waitForTimeout(60)
  }
  await owner.waitForSelector('#drawing-editor[data-pointers="1"]', { timeout: 5000 })
    .catch(() => fail("the friend's cursor did not reach the owner"))
  if (process.env.SHOTS) await owner.screenshot({ path: `${process.env.SHOTS}/owner-cursor.png` })
  console.log("ok: the friend's cursor shows on the owner's canvas")

  await rectangle(owner, 450, 250)
  if (process.env.SHOTS) await owner.screenshot({ path: `${process.env.SHOTS}/owner-1.png` })
  await waitShapes(owner, 1, 'the owner')
  await waitShapes(friend, 1, 'the friend')
  console.log("ok: the owner's rectangle reached the friend")

  await rectangle(friend, 800, 450)
  await waitShapes(friend, 2, 'the friend')
  await waitShapes(owner, 2, 'the owner')
  console.log("ok: the friend's rectangle reached the owner")

  await owner.locator('[data-drawing-status]', { hasText: 'Saved' }).waitFor({ timeout: 10000 })
    .catch(() => fail('the status never said Saved'))
  console.log('ok: it saved by itself')

  await open(owner)
  await waitShapes(owner, 2, 'the owner, after a reload')
  console.log('ok: both rectangles are there after a reload')
} finally {
  await browser.close()
}
