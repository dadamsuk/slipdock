// The browser half of tools/e2e/page-tools.sh.
//
//   node tools/e2e/page-tools.mjs <login-url> <base-url> <kb-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

const answer = '#page-tools-answer'
const connected = () => page.waitForSelector('.phx-connected')
const reading = `${base}/boards/${kb}/wiki/acme-call`

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // Reading: the panel sits beside the page, not over it.
  await page.goto(reading, { waitUntil: 'networkidle' })
  await connected()
  await page.click('#page-tools-toggle')
  await page.click('#page-tool-summarise')
  await page.waitForSelector(answer)
  if (!(await page.textContent(answer)).includes('Sharper words')) fail('no summary shown')
  const side = await page.locator('aside[id^=page-tools-]').boundingBox()
  const main = await page.locator('#wiki-main').boundingBox()
  if (side.x < main.x + main.width - 1) fail('the panel should sit beside the page')
  if (await page.locator('#page-tools-insert').count()) fail('reading has nothing to add to')
  console.log('ok: a summary beside the page')

  // Editing: the answer goes into the editor and saves with the page.
  await page.goto(`${reading}/edit`, { waitUntil: 'networkidle' })
  await connected()
  await page.click('#page-tools-toggle')
  await page.click('.cm-content')
  await page.keyboard.press('Control+End')
  await page.keyboard.type(' Typed just now.')
  await page.waitForTimeout(500)
  await page.click('#page-tool-improve')
  await page.waitForSelector(answer)
  await page.click('#page-tools-insert')
  await page.waitForFunction(() =>
    document.querySelector('#page_body').value.includes('Sharper words'))
  const body = await page.inputValue('#page_body')
  if (!/Typed just now\.\n\nSharper words from the model\.\n$/.test(body)) fail(`editor: ${JSON.stringify(body)}`)
  console.log('ok: Add to the page lands in the editor')

  await page.waitForTimeout(500)
  await page.click('#page-form button[type=submit]')
  await page.waitForSelector('article')
  await page.waitForFunction(() => document.querySelector('article').innerText.includes('Sharper words'))
  console.log('ok: and saves with the page')
  await page.screenshot({ path: 'tmp/page-tools.png' })

  // A phone: a sheet over the page, and the way out of it.
  await page.setViewportSize({ width: 390, height: 800 })
  await page.goto(reading, { waitUntil: 'networkidle' })
  await connected()
  await page.click('#page-tools-toggle')
  const sheet = await page.locator('aside[id^=page-tools-]').boundingBox()
  if (sheet.width < 380) fail(`the sheet is ${sheet.width} wide`)
  await page.click('#page-tools-close')
  await page.waitForSelector('aside[id^=page-tools-]', { state: 'detached' })
  console.log('ok: a sheet on a phone')
} finally {
  await browser.close()
}
