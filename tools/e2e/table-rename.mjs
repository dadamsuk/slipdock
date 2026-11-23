// The browser half of tools/e2e/table-rename.sh (#3670).
//
//   node tools/e2e/table-rename.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, id] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const shots = process.env.SHOTS

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const settle = () => page.waitForTimeout(500)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${board}/table?fields=title,color,priority`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  const row = page.locator(`tr[id$="-${id}"]`)
  const text = row.locator('[data-role=title-text]')
  const input = page.locator(`#title-input-${id}`)
  const pencil = row.locator('button[aria-label=Rename]')

  if (await input.isVisible()) fail('the rename box shows at rest')
  if ((await pencil.evaluate(e => getComputedStyle(e).opacity)) !== '0') fail('the pencil shows on a row not hovered')

  // Enter saves.
  await row.hover()
  await pencil.click()
  if (!(await input.isVisible())) fail('the pencil did not open the rename box')
  if (await text.isVisible()) fail('the title still shows beside the rename box')
  if (!(await input.evaluate(e => e === document.activeElement))) fail('the rename box has no focus')
  if (shots) await page.screenshot({ path: `${shots}/table-rename-open.png` })
  await input.fill('Renamed with Enter')
  await input.press('Enter')
  await settle()
  if ((await text.innerText()).trim() !== 'Renamed with Enter') fail(`after Enter the title reads ${await text.innerText()}`)
  if (await input.isVisible()) fail('the rename box stayed open after Enter')

  // Leaving the box saves too.
  await row.hover()
  await pencil.click()
  await input.fill('Renamed on blur')
  await page.locator('body').click({ position: { x: 5, y: 5 } })
  await settle()
  if ((await text.innerText()).trim() !== 'Renamed on blur') fail(`after blur the title reads ${await text.innerText()}`)
  if (await input.isVisible()) fail('the rename box stayed open after blur')

  // A reload shows the saved title.
  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  if ((await text.innerText()).trim() !== 'Renamed on blur') fail('the rename did not persist')

  // The colour is chosen in its cell.
  await page.selectOption(`#color-${id} select`, 'lime')
  await settle()
  if (!(await page.locator(`#color-${id} span.rounded-full`).count())) fail('no colour dot after picking lime')
  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  if ((await page.locator(`#color-${id} select`).inputValue()) !== 'lime') fail('the colour did not persist')
  if (shots) await page.screenshot({ path: `${shots}/table-rename-done.png` })

  // Clicking the title still opens the card.
  await text.click()
  await settle()
  if (!page.url().includes(`card`) && !(await page.locator('#card-modal, [data-card-panel]').count()))
    fail(`clicking the title opened nothing (url ${page.url()})`)

  console.log('ok: renamed with Enter and on blur, recoloured, and the title still opens the card')
} finally {
  await browser.close()
}
