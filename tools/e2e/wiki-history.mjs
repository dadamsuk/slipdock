// The browser half of tools/e2e/wiki-history.sh.
//
//   node tools/e2e/wiki-history.mjs <login-url> <base-url> <kb-id> <slug>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, slug] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const LONG = 'Self-serve trial sign-up flow'

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })
const connected = () => page.waitForSelector('.phx-connected')

// The tree's rows named LONG: whether each shows whole, and its title.
const longRows = () => page.$$eval('#wiki-tree .wt-row', (rows, long) => rows
  .filter((r) => r.textContent.includes(long.slice(0, 12)))
  .map((r) => {
    const name = r.querySelector('a > span.truncate')
    return { title: r.querySelector('a').getAttribute('title'), whole: name.scrollWidth <= name.clientWidth, text: name.textContent }
  }), LONG)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // 1. History: open a row onto its lines.
  await page.goto(`${base}/boards/${kb}/wiki/${slug}/history`, { waitUntil: 'networkidle' })
  await connected()
  const toggles = page.locator('[id^=revision-preview-toggle-]')
  if ((await toggles.count()) !== 4) fail(`want 4 history rows, got ${await toggles.count()}`)
  if (await page.locator('[data-role=revision-preview]').count()) fail('rows should start closed')

  const want = [
    [[ 'del', 'Ship on Friday.' ], [ 'ins', 'Ship on Monday.' ]], // newest: a changed paragraph
    [[ 'del', 'Old note.' ]],                                      // a removed one
    [[ 'ins', 'Added paragraph.' ]],                               // an added one
  ]
  for (let i = 0; i < want.length; i++) {
    const toggle = toggles.nth(i)
    await toggle.click()
    const id = (await toggle.getAttribute('aria-controls'))
    await page.waitForSelector(`#${id}`)
    if ((await toggle.getAttribute('aria-expanded')) !== 'true') fail('aria-expanded should follow the row')
    const got = await page.$$eval(`#${id} li[data-op]`, (lis) => lis.map((li) => [li.dataset.op, li.querySelector('span.min-w-0').textContent.trim()]))
    if (JSON.stringify(got) !== JSON.stringify(want[i])) fail(`row ${i}: ${JSON.stringify(got)} want ${JSON.stringify(want[i])}`)
    const colours = await page.$$eval(`#${id} li[data-op]`, (lis) => lis.map((li) => getComputedStyle(li).backgroundColor))
    if (want[i].length === 2 && colours[0] === colours[1]) fail('removed and added lines should be told apart')
  }
  console.log('ok: a changed, a removed and an added paragraph each show their lines')
  if (shots) await page.screenshot({ path: `${shots}/wiki-history.png` })

  // A second press closes the row again.
  await toggles.nth(0).click()
  await page.waitForFunction(() => document.querySelectorAll('[data-role=revision-preview]').length === 2)
  console.log('ok: a second press closes the row')

  // 2. The tree, at the default width, shows the long pair whole.
  await page.evaluate(() => { localStorage.removeItem('slipdock:wiki-tree-width') })
  await page.goto(`${base}/boards/${kb}/wiki/self-serve-trial-sign-up-flow`, { waitUntil: 'networkidle' })
  await connected()
  await page.waitForFunction((long) => [...document.querySelectorAll('#wiki-tree .wt-row')].filter((r) => r.textContent.includes(long)).length >= 2, LONG)
  const tree = await page.$eval('#wiki-tree', (t) => Math.round(t.getBoundingClientRect().width))
  const rows = await longRows()
  if (rows.length < 2) fail('want the folder and its page in the tree: ' + JSON.stringify(rows))
  for (const r of rows) {
    if (r.title !== LONG) fail(`a row's title is ${JSON.stringify(r.title)}`)
    if (!r.whole) fail(`"${r.text}" is cut at the ${tree}px default`)
  }
  console.log(`ok: the ${LONG.length}-character folder and page show whole at the ${tree}px default, title on each`)

  // Every row in the tree has its name in title.
  const untitled = await page.$$eval('#wiki-tree .wt-row a', (as) => as.filter((a) => !a.getAttribute('title')).length)
  if (untitled) fail(`${untitled} tree rows have no title`)
  console.log('ok: every tree row has its full name in title')
  if (shots) await page.locator('#wiki-tree').screenshot({ path: `${shots}/wiki-tree.png` })

  // The old 256px default, for the before picture: the pair was cut there.
  await page.evaluate(() => document.documentElement.style.setProperty('--wiki-tree-width', '256px'))
  const narrow = await longRows()
  if (shots) await page.locator('#wiki-tree').screenshot({ path: `${shots}/wiki-tree-256.png` })
  console.log(`(at the old 256px: ${narrow.filter((r) => !r.whole).length} of ${narrow.length} cut)`)
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
