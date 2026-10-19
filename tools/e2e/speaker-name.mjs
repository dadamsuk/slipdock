// The browser half of tools/e2e/speaker-name.sh (#1157).
//
//   node tools/e2e/speaker-name.mjs <login-url> <base-url> <board-id> <page-slug>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, slug] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1300, height: 800 } })

const speakers = () => page.locator('#wiki-body li[data-speaker]').evaluateAll((lis) => lis.map((li) => li.dataset.speaker))
const name = (who) => page.locator('#wiki-body .wiki-transcript-speaker', { hasText: who }).first()
const box = page.locator('#wiki-body [data-speaker-input]')
async function until(what, check, ms = 8000) {
  const end = Date.now() + ms
  while (Date.now() < end) { if (await check()) return; await page.waitForTimeout(100) }
  fail(what + ' — speakers: ' + JSON.stringify(await speakers()))
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${kb}/wiki/${slug}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('[data-transcript-player]').waitFor()

  const before = await speakers()
  if (JSON.stringify(before) !== JSON.stringify(['Speaker 1', 'Speaker 2', 'Speaker 1'])) fail('speakers at the start: ' + before)
  if ((await name('Speaker 1').getAttribute('title')) !== 'Name this voice') fail('the name has no hint')

  // Escape leaves it as it was.
  await name('Speaker 2').click()
  await box.waitFor()
  if ((await box.inputValue()) !== 'Speaker 2') fail('the box does not start with the name')
  await box.press('Escape')
  if (await box.count()) fail('Escape left the box open')
  if (!(await name('Speaker 2').isVisible())) fail('Escape did not put the name back')

  // Enter names the voice everywhere: a <v> tag and a "Name:" prefix.
  await name('Speaker 1').click()
  await box.fill('Priya Shah')
  await box.press('Enter')
  await until('Speaker 1 was not renamed', async () =>
    JSON.stringify(await speakers()) === JSON.stringify(['Priya Shah', 'Speaker 2', 'Priya Shah']))
  await page.locator('#flash-info', { hasText: 'is now “Priya Shah”' }).waitFor()

  // A second name, after the redraw: the box still opens, and naming a voice
  // after somebody already there makes them one speaker.
  await name('Speaker 2').click()
  await box.fill('Priya Shah')
  await box.press('Enter')
  await until('Speaker 2 was not merged', async () =>
    JSON.stringify(await speakers()) === JSON.stringify(['Priya Shah']))

  // The bar survived both redraws, and its search still works.
  await page.locator('[data-transcript-player] [data-search]').fill('budget')
  await until('search found nothing after the redraw', async () =>
    (await page.locator('#wiki-body li.is-match').count()) === 1)

  // A refused name says why, and changes nothing.
  await name('Priya Shah').click()
  await box.fill('a:b')
  await box.press('Enter')
  await page.locator('#flash-error', { hasText: 'without <, > or a colon' }).waitFor()

  // It was saved: a reload shows the names.
  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  if (JSON.stringify(await speakers()) !== JSON.stringify(['Priya Shah'])) fail('the names were not saved')

  console.log('PASS: speaker naming')
} catch (e) {
  await page.screenshot({ path: '/tmp/speaker-name-fail.png' }).catch(() => {})
  fail(e.message)
} finally {
  await browser.close()
}
