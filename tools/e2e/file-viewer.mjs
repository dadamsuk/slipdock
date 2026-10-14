// The browser half of tools/e2e/file-viewer.sh (#762, #768): open each file
// from the board's tree and check it shows in the page's place, beside the
// tree: two columns, not a third (#773).
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

// From the tree, click a file's row: it opens in the page's place, filling
// the width beside the tree, and the address and the tree stay put.
async function open(name) {
  await page.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const row = page.locator('.wt-row', { hasText: name }).first()
  await row.waitFor()
  await row.locator('a').first().click()
  await page.locator('#wiki-file-panel h2', { hasText: name }).waitFor()
  if (!page.url().endsWith(`/boards/${kb}/wiki`)) fail('the address moved: ' + page.url())
  if (!(await page.locator('#wiki-tree').isVisible())) fail('the tree went away')
  if (await page.locator('#wiki-main').isVisible()) fail('the page is still showing beside the file')
  const panel = await page.locator('#wiki-file-panel').boundingBox()
  const tree = await page.locator('#wiki-tree').boundingBox()
  if (!(panel.x >= tree.x + tree.width - 1)) fail('the file is not beside the tree')
  const width = page.viewportSize().width
  if (Math.abs(panel.x + panel.width - width) > 20) fail(`the file does not reach the edge: ${panel.x + panel.width} of ${width}`)
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

  // The download is always there.
  const [download] = await Promise.all([page.waitForEvent('download'), page.locator('#wiki-file-download').click()])
  if (download.suggestedFilename() !== 'Spec.pdf') fail('download name: ' + download.suggestedFilename())

  // HTML is drawn, in a frame whose scripts never run.
  await open('Report.html')
  const frame = page.frameLocator('#file-html')
  await frame.locator('#t', { hasText: 'Quarterly' }).waitFor()
  await page.waitForTimeout(500)

  // Escape puts the panel away.
  await page.keyboard.press('Escape')
  await page.locator('#wiki-file-panel').waitFor({ state: 'detached' })

  // A page's [[link]] to a file opens it in the page's place too; X brings
  // the page back.
  await page.goto(`${base}/boards/${kb}/wiki/files-home`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('#wiki-body a.wiki-file-link', { hasText: 'people.csv' }).click()
  await page.locator('#wiki-file-panel #file-table').waitFor()
  if (await page.locator('#wiki-body').isVisible()) fail('the page is still showing beside the file')
  await page.screenshot({ path: process.env.SHOT || '/tmp/file-viewer-panel.png' })
  await page.locator('#wiki-file-close').click()
  await page.locator('#wiki-file-panel').waitFor({ state: 'detached' })
  if (!(await page.locator('#wiki-body').innerText()).includes('The data')) fail('the page did not come back')
  await page.locator('#wiki-body a.wiki-file-link', { hasText: 'people.csv' }).click()
  await page.locator('#wiki-file-panel #file-table').waitFor()

  // The arrow still opens it on a page of its own.
  await Promise.all([page.waitForURL(/\/files\/\d+$/), page.locator('#wiki-file-full').click()])
  await page.waitForSelector('#file-viewer #file-table')

  if (dialogs.length) fail('a script ran: ' + dialogs.join(', '))
  console.log('ok: in the page\'s place — csv table, json tree, png, svg, pdf, download, sandboxed html; a page link; the page of its own')
} catch (e) {
  await page.screenshot({ path: '/tmp/file-viewer-fail.png' }).catch(() => {})
  fail(e.message)
} finally {
  await browser.close()
}
