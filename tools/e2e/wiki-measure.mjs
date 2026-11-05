// The browser half of tools/e2e/wiki-measure.sh.
//
//   node tools/e2e/wiki-measure.mjs <login-url> <base-url> <kb-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 1400, height: 1000 } })
await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: base })
const page = await context.newPage()
const connected = () => page.waitForSelector('.phx-connected')

// The right edge of every block the reader's eye runs along.
const edges = () => page.evaluate(() => {
  const pick = (sel) => [...document.querySelectorAll(sel)].map((el) => ({
    sel, right: Math.round(el.getBoundingClientRect().right), left: Math.round(el.getBoundingClientRect().left),
  }))
  return [
    ...pick('#wiki-body > p'), ...pick('#wiki-body > ul'), ...pick('#wiki-body > h2'),
    ...pick('#wiki-body > h3'), ...pick('#wiki-body > table'), ...pick('#page-cards'),
    ...pick('#page-actions'),
  ]
})

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${kb}/wiki/measured-page`, { waitUntil: 'networkidle' })
  await connected()
  if (shots) await page.screenshot({ path: `${shots}/wiki-measure.png`, fullPage: true })

  // 1. One measure.
  const blocks = await edges()
  const rights = new Set(blocks.map((b) => b.right))
  const lefts = new Set(blocks.map((b) => b.left))
  if (rights.size !== 1 || lefts.size !== 1) fail('blocks disagree: ' + JSON.stringify(blocks))
  const width = [...rights][0] - [...lefts][0]
  const ch = await page.evaluate(() => {
    const s = document.createElement('span'); s.textContent = '0'
    document.getElementById('wiki-body').appendChild(s)
    const w = s.getBoundingClientRect().width; s.remove(); return w
  })
  if (width / ch < 60 || width / ch > 76) fail(`measure is ${(width / ch).toFixed(1)}ch, want about 68`)
  console.log(`ok: ${blocks.length} blocks share one measure, ${Math.round(width)}px (${(width / ch).toFixed(1)}ch)`)

  // A wide table keeps to it: its box ends at the measure and its many
  // columns scroll inside, rather than splitting short words (#1169 keeps
  // long URLs breaking within a cell).
  const table = await page.$eval('#wiki-body > table', (t) => ({
    right: Math.round(t.getBoundingClientRect().right), sw: t.scrollWidth, cw: t.clientWidth,
    narrowest: Math.min(...[...t.querySelectorAll('th')].map((th) => th.getBoundingClientRect().width)),
  }))
  if (table.right > [...rights][0]) fail('the table runs past the measure')
  if (table.sw <= table.cw) fail('a twelve-column table should scroll inside the measure')
  if (table.narrowest < 90) fail(`a column is ${table.narrowest}px, short words split`)
  console.log('ok: the wide table keeps to the measure and scrolls inside it')

  // The full-width option still lets the column go wide.
  await page.evaluate(() => document.documentElement.setAttribute('data-wiki-width', 'full'))
  const fullWidth = await page.$eval('#wiki-body > p', (p) => p.getBoundingClientRect().width)
  if (fullWidth <= width + 50) fail(`full width should widen the text (${fullWidth} vs ${width})`)
  await page.evaluate(() => document.documentElement.removeAttribute('data-wiki-width'))
  console.log('ok: full width still widens the column')

  // 2. One button style, Edit the only emphasised one.
  const styles = await page.$$eval('#page-actions > .btn, #page-actions > a.btn, #page-actions .dropdown > .btn', (els) =>
    els.map((el) => ({
      text: el.textContent.trim(), ghost: el.classList.contains('btn-ghost'),
      bg: getComputedStyle(el).backgroundColor, border: getComputedStyle(el).borderTopWidth,
    })))
  const loud = styles.filter((s) => !s.ghost)
  if (loud.length !== 1 || !/Edit/.test(loud[0].text)) fail('Edit should be the one non-ghost action: ' + JSON.stringify(styles))
  const quiet = new Set(styles.filter((s) => s.ghost).map((s) => s.bg + s.border))
  if (quiet.size !== 1) fail('ghost buttons draw differently: ' + JSON.stringify(styles))
  if (await page.locator('#page-actions .chip').count()) fail('the page code is still a chip')
  console.log(`ok: ${styles.length - 1} ghost actions and one emphasised Edit`)

  // The page code copies from its button, and its tooltip says so.
  const code = page.locator('#page-code-copy')
  const tip = await code.getAttribute('data-tip')
  if (!/^W-\d+/.test(tip)) fail('the code button tooltip should start with the code: ' + tip)
  await code.click()
  const copied = await page.evaluate(() => navigator.clipboard.readText())
  if (copied !== tip.split(' ')[0]) fail(`copied ${JSON.stringify(copied)}, want ${tip.split(' ')[0]}`)
  await page.waitForFunction(() => document.getElementById('page-code-copy').dataset.tip === 'Copied')
  console.log(`ok: the code button copies ${copied}`)

  // 3. "Attach a card…" is a field, not a rounded-full box.
  const attach = page.locator('#page-card-search input')
  if (!(await attach.evaluate((el) => el.classList.contains('field')))) fail('Attach a card… should be a field')
  const radius = await attach.evaluate((el) => parseFloat(getComputedStyle(el).borderTopLeftRadius))
  if (radius > 10) fail(`Attach a card… radius ${radius}px, want the field's 8px`)
  console.log('ok: Attach a card… is a field')
  if (shots) await page.locator('#page-actions').screenshot({ path: `${shots}/wiki-actions.png` })
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
