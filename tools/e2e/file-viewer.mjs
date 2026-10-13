// The browser half of tools/e2e/file-viewer.sh (#762): open each file from
// the board's tree and check its viewer shows it.
//
//   node tools/e2e/file-viewer.mjs <login-url> <base-url> <board-id>
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
const dialogs = []
page.on('dialog', (d) => { dialogs.push(d.message()); d.dismiss() })

// From the tree, click a file's row and land in its viewer.
async function open(name) {
  await page.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const row = page.locator('.wt-row', { hasText: name }).first()
  await row.waitFor()
  await Promise.all([page.waitForURL(/\/files\/\d+$/), row.locator('a').first().click()])
  await page.waitForSelector('#file-viewer')
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await open('people.csv')
  const cell = await page.locator('#file-table tbody tr').nth(1).locator('td').first().innerText()
  if (cell !== 'Lovelace, A') fail('csv cell: ' + cell)

  await open('config.json')
  await page.locator('#file-json').getByText('"name"').waitFor()
  const inner = page.locator('#file-json details[data-json=array]')
  if (await inner.evaluate((d) => d.open)) fail('the third level should start folded')
  await inner.locator('summary').click()
  if (!(await inner.evaluate((d) => d.open))) fail('the array did not unfold')

  for (const name of ['dot.png', 'logo.svg']) {
    await open(name)
    const img = page.locator('#file-image')
    await page.waitForFunction(() => document.querySelector('#file-image').complete)
    const w = await img.evaluate((i) => i.naturalWidth)
    if (!w) fail(name + ' did not load')
  }

  await open('Spec.pdf')
  const src = await page.locator('#file-pdf').getAttribute('src')
  const res = await page.request.get(base + src)
  if (!res.headers()['content-type'].startsWith('application/pdf')) fail('pdf type: ' + res.headers()['content-type'])
  if (!res.headers()['content-disposition'].startsWith('inline')) fail('pdf disposition')
  await page.screenshot({ path: process.env.SHOT || '/tmp/file-viewer-pdf.png' })

  // The download is always there.
  const [download] = await Promise.all([page.waitForEvent('download'), page.locator('#file-download').click()])
  if (download.suggestedFilename() !== 'Spec.pdf') fail('download name: ' + download.suggestedFilename())

  if (dialogs.length) fail('a script ran: ' + dialogs.join(', '))
  console.log('ok: csv table, json tree, png, svg, pdf, download')
} catch (e) {
  await page.screenshot({ path: '/tmp/file-viewer-fail.png' }).catch(() => {})
  fail(e.message)
} finally {
  await browser.close()
}
