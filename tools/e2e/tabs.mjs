// The browser half of tools/e2e/tabs.sh (#1740): each tab bar is a
// tablist with one tab in the Tab order; the arrow keys, Home and End move
// along it, wrapping round the ends, and activate the tab they land on;
// and every bar looks the same.
//
//   node tools/e2e/tabs.mjs <login-url> <base-url> <board-id> <tool-slug>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board, tool] = process.argv.slice(2)
const shots = process.env.SHOTS
const before = process.env.BEFORE === '1'
const fail = (w) => { throw new Error(w) }

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(300)
}

// [name, path, the bar, the tab ids in order, each tab's panel id or null, url check]
const bars = [
  ['board-settings', `/boards/${board}/settings?tab=planning`, '#settings-tabs',
    ['general', 'features', 'planning', 'deploys', 'gardening', 'sharing', 'manage'].map((k) => `settings-tab-${k}`),
    (id) => id.replace('settings-tab-', 'settings-panel-'), null],
  ['search', '/search', '#look-tabs', ['look-tab-search', 'look-tab-ask'], () => null,
    (id) => (id === 'look-tab-ask' ? /\/ask$/ : /\/search$/)],
  ['tool', `/tools/${tool}`, '#tool-clients', ['tool-client-claude_ai', 'tool-client-claude_code', 'tool-client-chatgpt'],
    (id) => `tool-steps-${id.replace('tool-client-', '').replace('_', '-')}`, null],
]
// The old bars had no ids of their own: find them where they sat.
const beforeBar = { 'board-settings': '#settings-tabs', search: 'main [role=tablist]', tool: '#tool-steps [role=tablist]' }

async function selected(bar) {
  return page.locator(`${bar} [role=tab][aria-selected=true]`).getAttribute('id')
}

async function landsOn(name, bar, id, panelOf, urlOf) {
  await page.waitForFunction(([b, i]) => document.querySelector(`${b} [aria-selected=true]`)?.id === i, [bar, id], { timeout: 5000 })
    .catch(() => fail(`${name}: ${id} did not become selected`))
  const focused = await page.evaluate(() => document.activeElement?.id)
  if (focused !== id) fail(`${name}: focus is on ${focused}, not ${id}`)
  const inOrder = await page.locator(`${bar} [role=tab][tabindex="0"]`).evaluateAll((ns) => ns.map((n) => n.id))
  if (inOrder.length !== 1 || inOrder[0] !== id) fail(`${name}: the Tab order has ${inOrder}, not just ${id}`)
  const panel = panelOf(id)
  if (panel && !(await page.locator(`#${panel}`).isVisible())) fail(`${name}: panel ${panel} is not showing`)
  if (urlOf && !urlOf(id).test(new URL(page.url()).pathname)) fail(`${name}: url ${page.url()} after ${id}`)
}

// What "one look" means: the bar's well and the active and resting tabs.
async function look(bar) {
  const style = (sel) => page.locator(sel).first().evaluate((n) => {
    const s = getComputedStyle(n)
    return [s.backgroundColor, s.borderRadius, s.paddingTop, s.paddingLeft, s.fontSize, s.fontWeight, s.color, s.boxShadow].join(' | ')
  })
  return {
    well: await style(bar),
    active: await style(`${bar} [role=tab][aria-selected=true]`),
    resting: await style(`${bar} [role=tab][aria-selected=false]`),
  }
}

const looks = {}
for (const [name, path, bar, ids, panelOf, urlOf] of bars) {
  await open(path)
  if (shots) {
    await page.locator(before ? beforeBar[name] : bar).first().screenshot({ path: `${shots}/${before ? 'before' : 'after'}-tabs-${name}.png` })
  }
  if (before) continue

  const start = await selected(bar)
  const at = ids.indexOf(start)
  if (at < 0) fail(`${name}: no tab selected to start (${start})`)
  if (name === 'board-settings' && start !== 'settings-tab-planning') fail('?tab=planning did not open Planning')
  await page.locator(`#${start}`).focus()

  const last = ids.length - 1
  const moves = [
    ['ArrowRight', ids[(at + 1) % ids.length]],
    ['End', ids[last]],
    ['ArrowRight', ids[0]],     // round the end
    ['ArrowLeft', ids[last]],   // and back round the start
    ['Home', ids[0]],
  ]
  for (const [key, id] of moves) {
    await page.keyboard.press(key)
    await landsOn(name, bar, id, panelOf, urlOf)
  }
  // Tab leaves the bar, Shift+Tab comes back to the active tab, not the first.
  await page.keyboard.press('End')
  await landsOn(name, bar, ids[last], panelOf, urlOf)
  await page.keyboard.press('Tab')
  if (await page.evaluate(() => document.activeElement?.getAttribute('role')) === 'tab') fail(`${name}: Tab stayed in the bar`)
  await page.keyboard.press('Shift+Tab')
  if (await page.evaluate(() => document.activeElement?.id) !== ids[last]) fail(`${name}: Shift+Tab did not come back to the active tab`)

  // Let the colour transitions finish before reading the look.
  await page.mouse.move(0, 0)
  await page.waitForTimeout(600)
  looks[name] = await look(bar)
  console.log(`ok: ${name}: arrows, Home and End move along ${ids.length} tabs and activate them`)
}

if (!before) {
  const [first, ...rest] = Object.entries(looks)
  for (const [name, l] of rest) {
    for (const part of ['well', 'active', 'resting']) {
      if (l[part] !== first[1][part]) fail(`${name}'s ${part} tab looks different from ${first[0]}'s:\n  ${l[part]}\n  ${first[1][part]}`)
    }
  }
  console.log('ok: one look across board settings, Search/Ask and the Tool page')
}
await browser.close()
