// The browser half of tools/e2e/card-state.sh (#1117).
//
//   node tools/e2e/card-state.mjs <login-url> <base-url> <board-id> <slow-id> <build-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, slow, build, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }
const count = (sel) => page.locator(sel).count()

async function until(what, test) {
  for (let i = 0; i < 40; i++) {
    if (await test()) return
    await page.waitForTimeout(250)
  }
  fail(what)
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${board}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  const line = (await page.locator(`#card-${build} [data-role=state-line]`).innerText()).trim()
  if (!/^Running · runner-2 · /.test(line)) fail('no running line on the tile: ' + line)
  if ((await count(`#card-${build} [data-role=driver-mark][data-driver=agent]`)) !== 1) fail('no agent mark')
  console.log('ok: the running card says ' + line + ', with an agent mark')

  const chip = page.locator(`#card-${slow} [data-role=age-chip]`)
  if ((await chip.getAttribute('data-stuck')) !== 'true') fail('the slow card is not amber')
  if (!(await chip.innerText()).includes('1h over usual')) fail('chip reads ' + (await chip.innerText()))
  const colour = await chip.evaluate((el) => getComputedStyle(el).color)
  await shot('1-tiles')
  console.log('ok: the slow card is amber, ' + (await chip.innerText()) + ' (' + colour + ')')

  // Stuck shows it alone.
  await page.click('[title=Filter]')
  await page.click('[phx-click=filter_stuck]')
  await until('Stuck left other cards', async () => (await count('.kanban-card')) === 1)
  if ((await count(`#card-${slow}`)) !== 1) fail('Stuck hid the slow card')
  console.log('ok: Stuck shows the slow card alone')
  await page.click('[phx-click=filter_stuck]')
  await until('Stuck did not let go', async () => (await count('.kanban-card')) > 1)

  // Agent picks out the running card.
  await page.click('[phx-click=filter_driver][phx-value-driver=agent]')
  await until('Agent showed other cards', async () => (await count('.kanban-card')) === 1)
  if ((await count(`#card-${build}`)) !== 1) fail('Agent hid the running card')
  await shot('2-agent')
  await page.click('[phx-click=filter_driver][phx-value-driver=all]')
  await until('All did not bring the cards back', async () => (await count('.kanban-card')) > 1)
  console.log('ok: Agent shows the running card alone, All brings the rest back')
} catch (e) {
  await shot('error')
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
