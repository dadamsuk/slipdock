// The browser half of tools/e2e/job-log.sh (#1871).
//
//   node tools/e2e/job-log.mjs <login-url> <base-url> <board-id> <card-id> <job-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, job] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1600, height: 1000 } })).newPage()
const log = `#job-log-card-${job}`
const lines = () => page.locator(`${log}-lines li`).count()

async function until(what, test, seconds = 120) {
  for (let i = 0; i < seconds * 2; i++) {
    if (await test()) return
    await page.waitForTimeout(500)
  }
  fail(what)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  // The runner takes the job and the panel shows its log, open, updating.
  await until('the job panel never showed a live log', async () => (await page.locator(`${log}-toggle`).count()) > 0)
  await until('the log never said it was updating', async () => (await page.locator(`${log}-toggle`).innerText()).includes('updating'))

  // Lines arrive, and more after them, with no reload in between.
  await until('no line ever arrived', async () => (await lines()) > 0)
  const first = await lines()
  console.log(`first lines: ${first}`)
  await until('the log never grew without a reload', async () => (await lines()) > first)
  console.log(`then: ${await lines()}`)

  // A tool call opens to its whole input.
  const call = page.locator(`${log}-lines li[data-kind="tool"] details`).first()
  await until('no tool call line', async () => (await call.count()) > 0)
  await call.locator('summary').click()
  await until('the tool call did not open', async () => call.evaluate((d) => d.open))
  const input = await call.locator('pre').innerText()
  if (!input.includes('"command"')) fail('the opened call shows no command: ' + input)

  // A line someone opened stays open as more arrive.
  const before = await lines()
  await until('no more lines after opening one', async () => (await lines()) > before, 90)
  if (!(await call.evaluate((d) => d.open))) fail('the opened line closed when more arrived')

  await page.screenshot({ path: process.env.SHOT || '/tmp/job-log-e2e.png', fullPage: false })

  // The job ends: the log stops updating, and still reads.
  await until('the job never ended', async () =>
    !(await page.locator(`${log}-toggle`).innerText()).includes('updating'), 240)
  const text = await page.locator(`${log}-lines`).innerText()
  if (!text.includes('sleep 6')) fail('the finished log lost its lines')

  // Once ended (#1872): it says when the log goes, and Keep this log keeps it.
  await until('no expiry shown on the ended job', async () => (await page.locator(`${log}-expires`).count()) > 0, 30)
  const expires = await page.locator(`${log}-expires`).innerText()
  if (!expires.includes('unless kept')) fail('the expiry line reads: ' + expires)
  await page.locator(`${log}-keep`).click()
  await until('Keep this log never said where it went', async () => (await page.locator(`${log}-kept a`).count()) > 0, 30)
  const kept = await page.locator(`${log}-kept`).innerText()
  if (!/Pass \d+ \(\d{4}-\d\d-\d\d \d\d\.\d\d\)/.test(kept)) fail('the kept line reads: ' + kept)
  if (await page.locator(`${log}-keep`).count()) fail('Keep this log is still offered after keeping')
  await page.screenshot({ path: process.env.SHOT_KEPT || '/tmp/job-log-kept-e2e.png', fullPage: false })
  console.log('ok: ' + kept.trim())

  console.log('ok: the card showed the live log, growing, a call opened and stayed open')
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
