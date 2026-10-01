// Captures the README screenshots from a running server.
//
//   node tools/screenshots.mjs <login-url> [base-url] [out-dir]
//
// The login URL is a one-time magic link (see `tools/screenshots.sh`, which
// mints one and calls this). Shots land in docs/screenshots as 2x PNGs.
//
// Needs playwright-core and a Chrome or Chromium binary; CHROME_PATH says
// where that is (default /usr/bin/google-chrome), and NODE_PATH can point at
// a global playwright install rather than a local one.
import { createRequire } from 'node:module'
import { mkdir } from 'node:fs/promises'

// playwright-core may be installed locally or globally; ESM imports ignore
// NODE_PATH, so resolve it the CommonJS way and honour NODE_PATH ourselves.
const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base = 'http://127.0.0.1:4111', out = 'docs/screenshots'] = process.argv.slice(2)

if (!loginUrl) {
  console.error('usage: node tools/screenshots.mjs <login-url> [base-url] [out-dir]')
  process.exit(1)
}

const BOARD_NAME = process.env.DEMO_BOARD || 'Product Launch'

// name, path, and what to do once it has loaded. `:board` stands in for the
// demo board's id, which is found by following its link off the home page —
// the UI addresses boards by id, and ids depend on what else is in the
// database.
const shots = [
  ['boards', '/', null, { height: 620 }],
  ['board', '/boards/:board', null, { height: 720 }],
  ['card', '/boards/:board', async (page) => {
    await page.getByText('Finalise pricing page copy').first().click()
    await page.waitForTimeout(900)
  }],
  ['swimlanes', '/boards/:board/swimlanes'],
  ['table', '/boards/:board/table', null, { height: 760 }],
  ['timeline', '/boards/:board/timeline', null, { height: 640 }],
  ['calendar', '/boards/:board/calendar'],
  ['outline', '/boards/:board/outline', null, { height: 840 }],
  ['prioritise', '/boards/:board/prioritise', null, { height: 640 }],
  ['wiki', '/boards/:board/wiki/launch-runbook'],
  ['automations', '/boards/:board/automations'],
  ['work', '/work', null, { height: 780 }],
]

const mobile = [
  ['mobile-board', '/boards/:board', async (page) => {
    await page.getByRole('button', { name: /In Progress/ }).first().click()
    await page.waitForTimeout(600)
  }],
  ['mobile-boards', '/'],
]

await mkdir(out, { recursive: true })

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox', '--hide-scrollbars'],
})

async function capture(context, list, boardId, width) {
  const page = await context.newPage()
  for (const [name, path, after, opts] of list) {
    if (opts?.height) await page.setViewportSize({ width, height: opts.height })
    await page.goto(base + path.replace(':board', boardId), { waitUntil: 'networkidle' })
    await page.waitForTimeout(700)
    if (after) await after(page)
    await page.screenshot({ path: `${out}/${name}.png` })
    console.log(`${out}/${name}.png`)
    if (opts?.height) await page.setViewportSize({ width, height: 900 })
  }
  await page.close()
}

const desktop = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
  colorScheme: 'light',
})

// One magic link, one session — sign in, then reuse the cookie for both sizes.
const first = await desktop.newPage()
await first.goto(loginUrl, { waitUntil: 'networkidle' })
await first.goto(base + '/', { waitUntil: 'networkidle' })
await first.getByRole('link', { name: BOARD_NAME }).first().click()
await first.waitForURL(/\/boards\/\d+/)
const boardId = new URL(first.url()).pathname.split('/')[2]
await first.close()

await capture(desktop, shots, boardId, 1440)

const phone = await browser.newContext({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 3,
  isMobile: true,
  hasTouch: true,
  colorScheme: 'light',
  storageState: await desktop.storageState(),
})

await capture(phone, mobile, boardId, 390)

await browser.close()
