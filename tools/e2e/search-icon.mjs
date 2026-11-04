// The browser half of tools/e2e/search-icon.sh. For each search box, the
// element at the glass's centre is the glass itself (the input used to paint
// over it), and the input is a `field`: 8px corners, 28px tall. Then, on a
// phone, the board's box is folded behind a button until it is tapped, and a
// query keeps it open.
//
//   node tools/e2e/search-icon.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const fail = (w) => { throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({ viewport: { width: 1280, height: 800 } })
const page = await context.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const boxes = [
  ['board', `/boards/${board}`, '#board-search'],
  ['views toolbar', `/boards/${board}/table`, '#swim-search'],
  ['wiki tree', `/boards/${board}/wiki`, '#wiki-search'],
  ['wiki attach a card', `/boards/${board}/wiki/acme-call`, '#page-card-search'],
  ['search and ask', `/search`, '#deep-search'],
]

for (const [label, path, sel] of boxes) {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  const glass = page.locator(`${sel} .search-input-icon`)
  await glass.waitFor()
  const hit = await glass.evaluate((el) => {
    const r = el.getBoundingClientRect()
    const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
    const z = (e) => { const cs = getComputedStyle(e); return `${cs.position}/z${cs.zIndex}/${cs.display}` }
    return { same: top === el, tag: top && `${top.tagName}(${z(top)}) over glass(${z(el)}) at ${r.left},${r.top} ${r.width}x${r.height}`, w: r.width }
  })
  if (!hit.same) fail(`${label}: the glass is covered by ${hit.tag}`)
  if (hit.w < 12) fail(`${label}: the glass is ${hit.w}px wide`)
  const look = await page.locator(`${sel} input`).first().evaluate((el) => {
    const cs = getComputedStyle(el)
    return { radius: cs.borderTopLeftRadius, height: el.getBoundingClientRect().height }
  })
  if (look.radius !== '8px') fail(`${label}: corners are ${look.radius}, not 8px`)
  if (Math.abs(look.height - 28) > 0.5) fail(`${label}: ${look.height}px tall, not 28px`)
  // A click on the glass puts the cursor in the box (its label does that).
  if (!(await page.locator(`${sel} input`).first().isDisabled())) {
    await glass.click()
    const focused = await page.locator(`${sel} input`).first().evaluate((el) => el === document.activeElement)
    if (!focused) fail(`${label}: a click on the glass leaves the box unfocused`)
  }
  if (process.env.SHOTS) await page.locator(sel).screenshot({ path: `${process.env.SHOTS}/search-icon-${label.replaceAll(' ', '-')}.png` })
  console.log(`ok: ${label}: glass on top, ${look.radius} corners, ${look.height}px`)
}

// A phone: the box is a glass button until tapped; a query keeps it open.
const phone = await context.newPage()
await phone.setViewportSize({ width: 390, height: 800 })
await phone.goto(`${base}/boards/${board}`, { waitUntil: 'load' })
await phone.waitForSelector('.phx-connected')
if (!(await phone.locator('#board-search-box-toggle').isVisible())) fail('phone: no glass button')
if (await phone.locator('#board-search input').isVisible()) fail('phone: the box is open before a tap')
await phone.locator('#board-search-box-toggle').click()
await phone.locator('#board-search input').waitFor({ state: 'visible', timeout: 5000 }).catch(() => fail('phone: the tap did not open the box'))
await phone.locator('#board-search input').fill('zzz')
await phone.waitForSelector('#board-search-box.search-open')
await phone.waitForFunction(() => !document.querySelector('#board-search-box-toggle'))
const covered = await phone.locator('#board-search .search-input-icon').evaluate((el) => {
  const r = el.getBoundingClientRect()
  return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) !== el
})
if (covered) fail('phone: the glass is covered in the open box')
if (process.env.SHOTS) await phone.screenshot({ path: `${process.env.SHOTS}/search-icon-phone.png` })
console.log('ok: phone: folded until tapped, open with a query')
await browser.close()
