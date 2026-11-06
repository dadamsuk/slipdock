// The browser half of tools/e2e/cli-reference.sh: Help's CLI command
// reference (#1884), signed out, at desktop and phone width.
//
//   node tools/e2e/cli-reference.mjs <base-url>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [base] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (w) => { throw new Error(w) }
const ok = (w) => console.log(`ok: ${w}`)

const groups = ['cli-start-here', 'cli-find-anything', 'cli-auth', 'cli-admin', 'cli-read',
  'cli-favourites', 'cli-wiki', 'cli-folders', 'cli-your-wiki', 'cli-sync', 'cli-skills',
  'cli-tools', 'cli-meetings', 'cli-write', 'cli-view-options', 'cli-values', 'cli-output']

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await context.newPage()
const open = async (path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(200)
}
const snap = async (name, fullPage = false) => {
  if (shots) await page.screenshot({ path: `${shots}/${name}.png`, fullPage })
}
// The help page scrolls inside #help, not the window.
const noSideScroll = async (where) => {
  const over = await page.evaluate(() => {
    const doc = document.documentElement
    const help = document.getElementById('help')
    return { doc: doc.scrollWidth - doc.clientWidth, help: help.scrollWidth - help.clientWidth }
  })
  if (over.doc > 0 || over.help > 0) fail(`${where}: the page scrolls sideways (${JSON.stringify(over)})`)
}

for (const [w, h, label] of [[1440, 900, 'desktop'], [390, 844, 'phone']]) {
  await page.setViewportSize({ width: w, height: h })

  // The ways in, then the CLI's page, each with its link.
  await open('/help/agents')
  await page.click('#help-way-cli-reference')
  await page.waitForSelector('#cli-reference')
  if (!page.url().endsWith('/help/agents/cli/reference')) fail(`${label}: index link went to ${page.url()}`)
  await open('/help/agents/cli')
  await page.click('#help-cli-reference-link')
  await page.waitForSelector('#cli-reference')
  ok(`${label}: the agents index and the CLI page link to the reference`)

  const ids = await page.$$eval('#cli-reference section[data-group]', (s) => s.map((e) => e.id))
  if (JSON.stringify(ids) !== JSON.stringify(groups)) fail(`${label}: groups ${ids}`)
  const contents = await page.$$eval('#cli-reference-contents a', (a) => a.map((e) => e.getAttribute('href')))
  if (JSON.stringify(contents) !== JSON.stringify(groups.map((g) => `#${g}`))) fail(`${label}: contents ${contents}`)
  ok(`${label}: ${ids.length} groups in order, each in the contents`)
  await noSideScroll(label)
  await page.$eval('#help', (e) => e.scrollTo(0, 0))
  await snap(`cli-reference-${label}-top`)

  // Every block stays inside the page: long usage wraps, details scroll in their own box.
  const wide = await page.evaluate(() => {
    const help = document.getElementById('help').getBoundingClientRect()
    return [...document.querySelectorAll('#cli-reference [data-role=cli-command]')]
      .filter((e) => e.getBoundingClientRect().right > help.right + 1).length
  })
  if (wide) fail(`${label}: ${wide} commands run past the page's edge`)
  const pres = await page.$$eval('#cli-reference pre', (ps) => ps.map((p) => getComputedStyle(p).overflowX))
  if (pres.some((o) => o !== 'auto')) fail(`${label}: a details block doesn't scroll on its own`)
  ok(`${label}: every command fits; details blocks scroll on their own (${pres.length})`)

  // A contents link goes to its group.
  await page.click('#cli-reference-contents a[href="#cli-write"]')
  await page.waitForTimeout(300)
  const top = await page.$eval('#cli-write', (e) => e.getBoundingClientRect().top)
  if (top < -2 || top > 200) fail(`${label}: Write is at ${top}px after its contents link`)
  if (!page.url().endsWith('#cli-write')) fail(`${label}: the address has no #cli-write`)
  ok(`${label}: a contents link scrolls to its group`)
  // A long usage line (set-board, runner new) wraps: show one.
  await page.$eval('#cli-write', (e) => {
    const code = [...e.querySelectorAll('[data-role=cli-usage]')].find((c) => c.textContent.startsWith('runner new'))
    code.scrollIntoView({ block: 'start' })
  })
  await page.waitForTimeout(200)
  await snap(`cli-reference-${label}-long`)

  // The filter: narrow to one command, then to nothing, then back.
  await page.fill('#cli-reference-q', 'page ls')
  await page.waitForFunction(() => document.querySelectorAll('[data-role=cli-command]').length === 1)
  const only = await page.$eval('[data-role=cli-usage]', (e) => e.textContent)
  if (!only.startsWith('page ls')) fail(`${label}: the filter kept ${only}`)
  await page.$eval('#cli-reference-contents', (e) => e.scrollIntoView({ block: 'start' }))
  await snap(`cli-reference-${label}-filter`)
  await page.fill('#cli-reference-q', 'no-such-command')
  await page.waitForSelector('#cli-reference-none')
  await page.fill('#cli-reference-q', '')
  await page.waitForFunction((n) => document.querySelectorAll('#cli-reference section[data-group]').length === n, groups.length)
  ok(`${label}: the filter narrows to one command, says when none match, and clears`)
  await noSideScroll(`${label} after filtering`)
}

await browser.close()
console.log('ok')
