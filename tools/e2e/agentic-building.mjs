// The browser half of tools/e2e/agentic-building.sh (#2011).
//
//   node tools/e2e/agentic-building.mjs <login-url> <base-url> <board-id> <sub-board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board, sub] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (w) => { throw new Error(w) }

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await context.newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(400)
}
const theme = (t) => page.evaluate((t) => document.documentElement.setAttribute('data-theme', t), t)
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }

// --- Off: no menu item, and the page sends the owner to Features ----------
await open(`/boards/${board}`)
if (await page.locator('#board-share-agentic').count()) fail('the menu has Agentic Building while it is off')
await open(`/boards/${board}/agentic`)
await page.waitForURL(/settings\?tab=features/)
await page.waitForSelector('#board-agentic-building')
await page.locator('#settings-modal .kanban-modal-in').screenshot(shots ? { path: `${shots}/settings-features-light-1440.png` } : {})

// --- Turn it on from Features, then the menu item opens the page ----------
await page.locator('#board-agentic-building').check()
await page.locator('#board-form button[type=submit]').click()
await page.waitForTimeout(600)
await open(`/boards/${board}`)
await page.locator('[title="More"]').first().click()
const item = page.locator('#board-share-agentic')
await item.waitFor({ state: 'visible' })
await Promise.all([page.waitForURL(/\/agentic$/), item.click()])
await page.waitForSelector('.phx-connected')
await page.waitForSelector('#agentic-title')
console.log('ok: the switch puts Agentic Building on the board menu, and it opens the page')

// --- The page --------------------------------------------------------------
const onRules = await page.$$eval('#agentic-summary [data-on=true]', (els) => els.map((e) => e.id))
for (const id of ['agentic-rule-verify', 'agentic-rule-evidence', 'agentic-rule-lanes', 'agentic-rule-ship', 'agentic-rule-profiles'])
  if (!onRules.includes(id)) fail(`the strip doesn't show ${id} on: ${onRules}`)
if (onRules.includes('agentic-rule-bar')) fail('the strip shows the bar on')
const sections = await page.$$eval('.agentic-section', (els) => els.map((e) => e.id))
if (sections.length !== 7) fail(`${sections.length} sections: ${sections}`)
console.log(`ok: strip with ${onRules.length} rules on, ${sections.length} sections`)

const pageWidth = await page.locator('[data-page-width]').first().evaluate((el) => el.getBoundingClientRect().width)
if (pageWidth > 1025) fail(`the page is ${pageWidth}px wide, over the standard 64rem`)

// Dark and light at 1440: the top of the page, then all of it.
for (const t of ['light', 'dark']) {
  await theme(t)
  await page.waitForTimeout(200)
  await shot(`agentic-${t}-1440`)
  await page.setViewportSize({ width: 1440, height: 3000 })
  await page.waitForTimeout(200)
  await shot(`agentic-${t}-1440-full`)
  await page.setViewportSize({ width: 1440, height: 900 })
}
await theme('light')

// A strip chip jumps to its section.
await page.locator('#agentic-rule-lanes').click()
await page.waitForTimeout(400)
const lanesTop = await page.locator('#agentic-lanes').evaluate((el) => el.getBoundingClientRect().top)
if (lanesTop < 0 || lanesTop > 200) fail(`the Lanes chip left its section at ${lanesTop}px`)

// Tick the bar, save, and the strip says so.
await page.locator('#board-bar-required').check()
await page.locator('#agentic-save-button').click()
await page.waitForSelector('#agentic-rule-bar[data-on=true]')
const saveBar = await page.locator('#agentic-save').evaluate((el) => getComputedStyle(el).position)
if (saveBar !== 'sticky') fail(`the save bar is ${saveBar}`)
console.log('ok: a rule ticked and saved shows on in the strip; the save bar stays in view')

// --- Phone width ------------------------------------------------------------
await page.setViewportSize({ width: 390, height: 844 })
await open(`/boards/${board}/agentic`)
for (const t of ['light', 'dark']) {
  await theme(t)
  await page.waitForTimeout(200)
  const wide = await page.evaluate(() => {
    const out = []
    for (const el of document.querySelectorAll('#agentic-shell *')) {
      const r = el.getBoundingClientRect()
      if (r.width && r.right > window.innerWidth + 1) out.push(`${el.tagName}#${el.id}.${el.className}`.slice(0, 80))
    }
    return { doc: document.documentElement.scrollWidth, out: out.slice(0, 5) }
  })
  if (wide.doc > 390 || wide.out.length) fail(`${t}: wider than the phone: ${JSON.stringify(wide)}`)
  await shot(`agentic-${t}-390`)
  await page.setViewportSize({ width: 390, height: 3600 })
  await page.waitForTimeout(200)
  await shot(`agentic-${t}-390-full`)
  await page.setViewportSize({ width: 390, height: 844 })
}
await theme('light')
console.log('ok: nothing wider than a 390px phone, light or dark')

// --- A sub-board: the root-only settings read-only, linked to the root ---
await page.setViewportSize({ width: 1440, height: 900 })
if (sub) {
  await open(`/boards/${sub}/agentic`)
  if (await page.locator('#board-tier-docs').count()) fail('the sub-board offers the human tier')
  if (!(await page.locator('#board-profile-tiers-read').count())) fail('the sub-board shows no human tier')
  const link = await page.locator('#board-job-logs [data-role=set-on-root] a').getAttribute('href')
  if (link !== `/boards/${board}/agentic`) fail(`the job logs link to ${link}`)
  await page.locator('#agentic-runners').scrollIntoViewIfNeeded()
  await shot('agentic-sub-board-1440')
  console.log('ok: a sub-board shows the human tier and job logs read-only, linking to the root')
}

// --- Turning it off warns which rules still hold --------------------------
await open(`/boards/${board}/settings?tab=features`)
await page.locator('#board-agentic-building').uncheck()
await page.waitForSelector('#board-agentic-warning')
const warning = await page.locator('#board-agentic-warning').innerText()
if (!/A second agent verifies/.test(warning) || !/A bar before work starts/.test(warning)) fail(`warning: ${warning}`)
await page.locator('#settings-modal .kanban-modal-in').screenshot(shots ? { path: `${shots}/settings-off-warning-light-1440.png` } : {})
console.log('ok: unticking it names the rules that still hold')

await browser.close()
console.log('ok')
