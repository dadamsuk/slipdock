// The browser half of tools/e2e/meeting-player.sh (W-1690, #780, #781, #785).
//
//   node tools/e2e/meeting-player.mjs <login-url> <base-url> <board-id> <meeting-slug> <missing-slug>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, meeting, missing] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1300, height: 800 } })
const recordingRequests = []
page.on('request', (r) => { if (r.url().includes('/recording')) recordingRequests.push(r.url()) })

const turn = (ms) => page.locator(`#wiki-body li[data-start-ms="${ms}"]`)
const current = () => page.locator('#wiki-body li.is-current').getAttribute('data-start-ms')
const seconds = async () => {
  const [m, s] = (await page.locator('[data-transcript-player] [data-time]').innerText()).split(':').map(Number)
  return m * 60 + s
}
async function until(what, check, ms = 8000) {
  const end = Date.now() + ms
  while (Date.now() < end) { if (await check()) return; await page.waitForTimeout(100) }
  fail(what)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${kb}/wiki/${meeting}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  // The bar sits under ## Recording, and nothing is fetched before play.
  const bar = page.locator('h2#recording + [data-transcript-player]')
  await bar.waitFor()
  if (recordingRequests.length) fail('the recording was fetched before play: ' + recordingRequests)

  // The page's own link plays it.
  await page.locator('#wiki-body a[href="#recording"]', { hasText: 'Play recording' }).click()
  await until('the play button never turned to pause',
    async () => (await bar.locator('[data-action="toggle"]').getAttribute('aria-label')) === 'Pause')
  if (!recordingRequests.length) fail('play did not ask for the recording')
  await until('time did not move', async () => (await seconds()) >= 2)
  await until('the first turn was not highlighted', async () => (await current()) === '1500')

  // Clicking a turn seeks there, and the highlight moves on as it plays.
  await turn(4000).click()
  await until('clicking a turn did not seek to it', async () => (await current()) === '4000')
  await until('the highlight did not follow playback', async () => (await current()) === '8000', 9000)

  // A turn far down: seek, then the turn is in view.
  await turn(65000).click()
  await until('seeking to 1:05 failed', async () => (await seconds()) >= 65)
  if (!(await turn(65000).isVisible())) fail('the current turn is not in view')
  const box = await turn(65000).boundingBox()
  if (box.y < 0 || box.y > 800) fail('the current turn was not scrolled into view: ' + box.y)
  // The bar has stayed in view while the transcript scrolled under it.
  await page.waitForTimeout(800)
  const barBox = await bar.boundingBox()
  const headingBox = await page.locator('h2#recording').boundingBox()
  if (headingBox.y > 0) fail('the page did not scroll past the heading')
  if (barBox.y < 0 || barBox.y > 150) {
    const chain = await bar.evaluate((el) => { const out = []; for (let e = el.parentElement; e; e = e.parentElement) { const cs = getComputedStyle(e); if (cs.overflow !== 'visible' || cs.overflowX !== 'visible' || cs.overflowY !== 'visible') out.push(`${e.tagName}#${e.id}.${e.className} ${cs.overflowX}/${cs.overflowY}`) } return out })
    fail('the bar did not stay at the top: ' + barBox.y + ' position=' + (await bar.evaluate((el) => getComputedStyle(el).position)) + '\n' + chain.join('\n'))
  }

  if (process.env.SHOT) await page.screenshot({ path: process.env.SHOT })

  // Scrolling by hand stops following; Follow starts it again.
  await turn(12000).click()
  await page.mouse.move(600, 400)
  await page.mouse.wheel(0, -600)
  const follow = bar.locator('[data-action="follow"]')
  await until('scrolling by hand did not offer Follow', () => follow.isVisible())
  await follow.click()
  await until('Follow did not hide', async () => !(await follow.isVisible()))

  // Keys: ] is faster, space pauses.
  await page.locator('body').click({ position: { x: 5, y: 5 } })
  await page.keyboard.press(']')
  if ((await bar.locator('[data-speed]').inputValue()) !== '1.25') fail('] did not speed up')
  await page.keyboard.press(' ')
  await until('space did not pause',
    async () => (await bar.locator('[data-action="toggle"]').getAttribute('aria-label')) === 'Play')

  // Search marks the turns and steps through them.
  await bar.locator('[data-search]').fill('budget')
  if ((await bar.locator('[data-hits]').innerText()) !== '1/2') fail('search count: ' + (await bar.locator('[data-hits]').innerText()))
  if ((await page.locator('#wiki-body li.is-match').count()) !== 2) fail('search did not mark two turns')
  await bar.locator('[data-search]').press('Enter')
  if ((await bar.locator('[data-hits]').innerText()) !== '2/2') fail('Enter did not step to the next match')

  // A tag pressed during the recording sits in its turn and seeks to its moment (#785).
  const tag = page.locator('#wiki-body li[data-start-ms="8000"] .wiki-transcript-tag[data-tag="decision"]')
  if ((await tag.innerText()).trim() !== '#decision 0:10') fail('tag chip said: ' + (await tag.innerText()))
  await tag.click()
  // Straight to 0:10, not to the turn's 0:08 and played on from there.
  await until('clicking a tag did not seek to it', async () => (await current()) === '8000' && (await seconds()) >= 10, 600)
  if ((await seconds()) > 11) fail('the tag seeked past its moment: ' + (await seconds()))

  // A recording that isn't on Drive says so.
  await page.goto(`${base}/boards/${kb}/wiki/${missing}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('[data-transcript-player] [data-action="toggle"]').click()
  const problem = page.locator('[data-transcript-player] [data-problem]')
  await until('no error was shown', () => problem.isVisible())
  const text = await problem.innerText()
  if (text !== 'Recording not found on Drive.') fail('error said: ' + text)

  console.log('ok: meeting player plays from Drive in time with its transcript')
} catch (e) {
  await page.screenshot({ path: '/tmp/meeting-player-fail.png' }).catch(() => {})
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
