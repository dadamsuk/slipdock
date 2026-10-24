// The browser half of tools/e2e/meta-actions.sh (#1230).
//
//   node tools/e2e/meta-actions.mjs <login-url> <base-url> <board-id> <card-id> [shots-dir]
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()

const transparent = (c) => c === 'rgba(0, 0, 0, 0)' || c === 'transparent'

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-title-form')

  const actions = page.locator('#card-title-form .meta-action')
  const n = await actions.count()
  if (n < 3) fail(`${n} meta actions on the line, want at least 3`)
  for (let i = 0; i < n; i++) {
    const l = await actions.nth(i).evaluate((el) => {
      const s = getComputedStyle(el)
      return { border: s.borderTopWidth, style: s.borderTopStyle, bg: s.backgroundColor, text: el.innerText.trim() }
    })
    if (l.border !== '1px' || l.style !== 'solid') fail(`"${l.text}" has no 1px border (${l.border} ${l.style})`)
    if (transparent(l.bg)) fail(`"${l.text}" has no background fill`)
    console.log(`ok: "${l.text}" is drawn as a button (1px border, ${l.bg})`)
  }

  const created = page.locator('#card-title-form span', { hasText: 'created' })
  const plain = await created.first().evaluate((el) => getComputedStyle(el).borderTopWidth)
  if (plain !== '0px') fail('the plain "created" text has a border')
  console.log('ok: the plain "created" text is not')

  if (shots) await page.locator('#card-title-form').screenshot({ path: `${shots}/meta-line.png` })
} finally {
  await browser.close()
}
