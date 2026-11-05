// The browser half of tools/e2e/page-header.sh (#1714). At 1440x900 every
// page below has one h1 with the expected title, inside one
// [data-page-width] frame whose rendered width matches its kind: narrow is
// 42rem (672px), standard 64rem (1024px), full the whole window. On home and
// Templates the header's first button's text sits on the title's baseline
// (within 1.5px) and the buttons are at the header's right edge.
//
//   node tools/e2e/page-header.mjs <login-url> <base-url> <kb-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, kb] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }
const shots = process.env.SHOTS
const shotsOnly = process.env.SHOTS_ONLY === '1'
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await context.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.mouse.move(5, 5)
}

if (shotsOnly) {
  for (const [path, name] of [['/', 'home'], ['/templates', 'templates']]) {
    await open(path)
    await page.screenshot({ path: `${shots}/page-header-${name}.png` })
  }
  await browser.close()
  process.exit(0)
}

const pages = [
  ['/', 'Boards', 'full'],
  ['/templates', 'Templates', 'standard'],
  ['/groups', 'Groups', 'standard'],
  ['/work', 'My work', 'standard'],
  ['/account', 'Account', 'standard'],
  ['/wiki/.settings', 'Wiki settings', 'narrow'],
  [`/boards/${kb}/visualise`, 'Visualise', 'full'],
  [`/boards/${kb}/tidy`, 'Tidy up', 'standard'],
  // The Admin area (#1738): one title over every admin page.
  ['/users', 'Admin', 'full'],
]
const expected = { narrow: 672, standard: 1024 }

for (const [path, title, width] of pages) {
  await open(path)
  const h1s = await page.locator('h1').allInnerTexts()
  if (h1s.length !== 1) fail(`${path} has ${h1s.length} h1s: ${JSON.stringify(h1s)}`)
  const text = h1s[0].replace(/\s+/g, ' ').trim()
  if (text !== title) fail(`${path}'s h1 is ${JSON.stringify(text)}, not ${JSON.stringify(title)}`)
  if (await page.locator('h1 img').count()) fail(`${path}'s h1 is an image`)
  const frames = page.locator('[data-page-width]')
  if ((await frames.count()) !== 1) fail(`${path} has ${await frames.count()} page frames`)
  const kind = await frames.getAttribute('data-page-width')
  if (kind !== width) fail(`${path} is ${kind}, not ${width}`)
  const box = await frames.boundingBox()
  if (width === 'full') {
    // The whole window, less the frame's scroller (and any scrollbar).
    if (box.width < 1440 - 40) fail(`${path} is full but only ${box.width}px wide`)
  } else if (Math.abs(box.width - expected[width]) > 1) {
    fail(`${path} is ${width} but ${box.width}px wide, not ${expected[width]}`)
  }
  if (width !== 'full' && Math.abs(box.x + box.width / 2 - 720) > 12) fail(`${path} isn't centred: x=${box.x}`)
  console.log(`ok ${path}: one h1 "${text}", ${width} ${Math.round(box.width)}px`)
}

// Where a piece of text's baseline is: a zero-height inline-block set on the
// baseline before its first letter. A text node straight inside a flex box
// (a button) is wrapped first, so the probe is inline with the text rather
// than a flex item of its own.
const baseline = (selector) => page.evaluate((selector) => {
  const el = document.querySelector(selector)
  if (!el) return null
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => {
      if (!n.textContent.trim()) return NodeFilter.FILTER_REJECT
      const p = n.parentElement
      return p && p.offsetParent !== null && getComputedStyle(p).display !== 'none'
        ? NodeFilter.FILTER_ACCEPT
        : NodeFilter.FILTER_REJECT
    },
  })
  const node = walker.nextNode()
  if (!node) return null
  let host = node.parentElement
  let wrap = null
  if (/flex|grid/.test(getComputedStyle(host).display)) {
    wrap = document.createElement('span')
    node.replaceWith(wrap)
    wrap.appendChild(node)
    host = wrap
  }
  const probe = document.createElement('span')
  probe.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline'
  node.before(probe)
  const y = probe.getBoundingClientRect().top
  probe.remove()
  if (wrap) wrap.replaceWith(node)
  return y
}, selector)

for (const [path, name, action] of [['/', 'home', '#reorder-boards'], ['/templates', 'templates', '#new-template']]) {
  await open(path)
  if (shots) await page.screenshot({ path: `${shots}/page-header-${name}.png` })
  const title = await baseline('[data-role=page-header] h1')
  const button = await baseline(`[data-role=page-actions] ${action}`)
  if (title === null || button === null) fail(`${path}: no title or no ${action} to measure`)
  const off = Math.abs(title - button)
  if (off > 1.5) fail(`${path}: ${action}'s text is ${off.toFixed(1)}px off the title's baseline`)
  const header = await page.locator('[data-role=page-header]').boundingBox()
  const actions = await page.locator('[data-role=page-actions]').boundingBox()
  if (Math.abs(header.x + header.width - (actions.x + actions.width)) > 2) fail(`${path}: the actions aren't at the right edge`)
  const h1 = await page.locator('[data-role=page-header] h1').boundingBox()
  if (actions.y > h1.y + h1.height) fail(`${path}: the actions wrapped below the title`)
  console.log(`ok ${path}: ${action} on the title's baseline (${off.toFixed(2)}px)`)
}

await browser.close()
console.log('page-header: ok')
