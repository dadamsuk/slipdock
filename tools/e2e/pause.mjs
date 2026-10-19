// The browser half of tools/e2e/pause.sh (#1116).
//
//   node tools/e2e/pause.mjs <login-url> <base-url> <board-id> <sub-board-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, sub, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
page.on('dialog', (d) => d.accept())
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }
const count = (sel) => page.locator(sel).count()

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // The whole tree: a reason first.
  await open(`/boards/${board}/automations`)
  await page.click('#pause-tree')
  await page.waitForSelector('#pause-form')
  if (!(await page.locator('#pause-submit').isDisabled())) fail('Pause is enabled with no reason')
  await page.fill('#pause-reason', '   ')
  await page.waitForTimeout(400)
  if (!(await page.locator('#pause-submit').isDisabled())) fail('Pause is enabled with a blank reason')
  await page.fill('#pause-reason', 'bad deploy')
  await until('Pause stayed disabled with a reason', async () => !(await page.locator('#pause-submit').isDisabled()))
  await shot('1-form')
  await page.click('#pause-submit')
  await until('no paused line in the panel', async () => (await count('#runners-tree-paused')) === 1)
  console.log('ok: Pause waited for a reason, then paused the tree')

  // The banner, on the board and on its sub-board, naming the root.
  await open(`/boards/${board}`)
  const banner = page.locator('[id^=pause-banner-]')
  if (!(await banner.innerText()).includes('bad deploy')) fail('no banner on the board')
  await shot('2-banner')
  await open(`/boards/${sub}`)
  const subText = await page.locator('[id^=pause-banner-]').innerText()
  if (!subText.includes('Paused on') || !subText.includes('bad deploy')) fail('no banner on the sub-board: ' + subText)
  console.log('ok: the banner shows on the board and its sub-board')

  // Resume from the sub-board's banner lets the tree off.
  await page.click('[id^=resume-pause-]')
  await until('the banner stayed after Resume', async () => (await count('[id^=pause-banner-]')) === 0)
  console.log('ok: Resume on the banner let it off')

  // A pool's own pause, from its row.
  await open(`/boards/${board}/automations`)
  await page.click('#pause-pool-dev')
  await page.fill('#pause-reason', 'flaky box')
  await until('Pause stayed disabled', async () => !(await page.locator('#pause-submit').isDisabled()))
  await page.click('#pause-submit')
  await until('the pool row is not paused', async () => (await page.locator('#runner-pool-dev').innerText()).includes('flaky box'))
  await shot('3-pool')
  await page.click('#resume-pool-dev')
  await until('the pool stayed paused', async () => (await count('#pause-pool-dev')) === 1)
  console.log('ok: the pool row paused and resumed just that pool')
} catch (e) {
  await shot('error')
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
