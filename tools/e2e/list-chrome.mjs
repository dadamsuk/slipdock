// The browser half of tools/e2e/list-chrome.sh (#1710).
//
//   node tools/e2e/list-chrome.mjs <login-url> <base-url> <board-id> <favourite-list-id>
//
// MEASURE_ONLY=1 prints the measurements without failing (for a before shot).
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, favList] = process.argv.slice(2)
const problems = []
const fail = (w) => problems.push(w)
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })

// The sign-in link works once, so one page, resized between the widths.
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

for (const [width, height] of [[1440, 900], [1280, 800]]) {
  await page.setViewportSize({ width, height })
  await page.goto(`${base}/boards/${board}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')

  // Hearts: only the favourite list's header wears one.
  const hearts = await page.$$eval('.column-handle > button[phx-click=toggle_favourite]', (bs) =>
    bs.map((b) => b.closest('.kanban-column').dataset.id))
  if (hearts.length !== 1 || hearts[0] !== favList) fail(`${width}: header hearts on lists ${JSON.stringify(hearts)}, want only ${favList}`)

  // The ⋯ menu offers favouriting on a list that isn't one.
  const other = await page.$$eval('.kanban-column', (cs, fav) => cs.map((c) => c.dataset.id).find((id) => id !== fav), favList)
  const menuItem = page.locator(`#column-${other} [data-role=favourite-list]`)
  if ((await menuItem.count()) !== 1) fail(`${width}: no Favourite item in list ${other}'s ⋯ menu`)
  else if (!/Favourite this list/.test(await menuItem.textContent())) fail(`${width}: menu item reads "${(await menuItem.textContent()).trim()}"`)

  // Footer actions: each has an accessible name and a tooltip.
  const footer = await page.$$eval(`#column-${favList} [data-role=list-footer] :is(a, button)`, (es) =>
    es.map((e) => ({ label: e.getAttribute('aria-label'), title: e.getAttribute('title'), text: e.textContent.trim() })))
  if (footer.length === 0) fail(`${width}: no list footer actions found`)
  for (const f of footer) if (!f.label || !f.title) fail(`${width}: footer action ${JSON.stringify(f)} lacks aria-label or title`)
  if (!footer.some((f) => f.text === 'Add card')) fail(`${width}: footer has no "Add card" label: ${JSON.stringify(footer)}`)

  // Count badge: not monospaced, same style for empty lists and WIP.
  const badgeFonts = await page.$$eval('[data-role=list-count]', (bs) => bs.map((b) => getComputedStyle(b).fontFamily))
  if (badgeFonts.length === 0) fail(`${width}: no list count badges`)
  if (badgeFonts.some((f) => /mono/i.test(f))) fail(`${width}: a count badge is monospaced: ${badgeFonts[0]}`)

  // Add another list: list width, and wholly visible at the right edge.
  await page.$eval('#board-scroll', (s) => { s.scrollLeft = s.scrollWidth })
  await page.waitForTimeout(200)
  const listBox = await page.locator(`#column-${favList}`).boundingBox()
  const add = page.locator('[data-role=add-list], button:has-text("Add another list")').first()
  const addBox = await add.boundingBox()
  const scroller = await page.locator('#board-scroll').boundingBox()
  if (!addBox) fail(`${width}: Add another list not shown`)
  else {
    if (Math.abs(addBox.width - listBox.width) > 1) fail(`${width}: Add another list is ${addBox.width}px wide, a list ${listBox.width}px`)
    if (addBox.x + addBox.width > scroller.x + scroller.width - 1) fail(`${width}: Add another list ends at ${addBox.x + addBox.width}, the board at ${scroller.x + scroller.width}`)
    console.log(`${width}: list ${listBox.width}px, add-list ${addBox.width}px ending ${(scroller.x + scroller.width - addBox.x - addBox.width).toFixed(1)}px inside the edge; hearts ${hearts.length}; footer ${JSON.stringify(footer.map((f) => f.text || f.title))}`)
  }
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/list-chrome-${width}.png` })
}
await browser.close()
if (problems.length) {
  console.log(problems.map((p) => `FAIL ${p}`).join('\n'))
  if (!process.env.MEASURE_ONLY) process.exit(1)
} else console.log('ok: list chrome recedes at 1440 and 1280')
