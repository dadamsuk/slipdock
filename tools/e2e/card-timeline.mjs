// The browser half of tools/e2e/card-timeline.sh (#1131).
//
//   node tools/e2e/card-timeline.mjs <login-url> <base-url> <board-id> <card-id> <job-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, job, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png`, fullPage: true }) }

// A span's box, in pixels, inside its lane.
const box = async (lane, label) => {
  const el = page.locator(`#card-timeline-${lane} [data-timeline-span="${label}"]`)
  if ((await el.count()) !== 1) fail(`no ${label} span in the ${lane} lane`)
  return el.boundingBox()
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-timeline')
  await page.locator('#card-timeline').scrollIntoViewIfNeeded()

  const todo = await box('stays', 'To Do')
  const doing = await box('stays', 'In Progress')
  const wait = await box('waits', 'on anyone')
  const jobBox = await box('jobs', `#${job} queued`)

  // Ten hours in all: six in To Do, then four in progress.
  if (!(todo.x < doing.x)) fail('In Progress is not after To Do')
  const ratio = todo.width / doing.width
  if (ratio < 1.3 || ratio > 1.7) fail(`To Do:In Progress widths ${todo.width}:${doing.width}, want ~6:4`)
  console.log(`ok: To Do (${Math.round(todo.width)}px) then In Progress (${Math.round(doing.width)}px), ~6:4`)

  if (!(wait.x > todo.x + todo.width - 2 && wait.x < jobBox.x)) fail('the wait is not between the move and the job')
  if (!(jobBox.x + jobBox.width > doing.x + doing.width - 3)) fail('the open job does not run to now')
  console.log('ok: the wait sits after the move, the open job runs to now')

  const colour = await page.locator('#card-timeline-stays [data-timeline-span="In Progress"]')
    .evaluate((el) => getComputedStyle(el).backgroundColor)
  if (/rgba\(0, 0, 0, 0\)|transparent/.test(colour)) fail('the In Progress span has no colour (stale CSS?)')
  console.log('ok: spans are coloured, In Progress is ' + colour)

  const title = await page.locator('#card-timeline-stays [data-timeline-span="In Progress"]').getAttribute('title')
  if (!/for 4h so far, by /.test(title)) fail('In Progress title: ' + title)
  await page.click('#card-timeline-list summary')
  const list = await page.locator('#card-timeline-list').innerText()
  if (!/2 stays in lists/.test(list) || !/6h/.test(list)) fail('stays list: ' + list)
  console.log('ok: hover title "' + title + '", and the stays list opens')
  await shot('timeline')
} catch (e) {
  await shot('error')
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
