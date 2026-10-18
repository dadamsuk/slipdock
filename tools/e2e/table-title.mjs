// The browser half of tools/e2e/table-title.sh (#1108).
//
//   node tools/e2e/table-title.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, id] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await page.goto(`${base}/boards/${board}/table`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-table')

  const m = await page.evaluate((id) => {
    const table = document.getElementById('card-table')
    const row = document.querySelector(`tr[id$="-${id}"]`)
    const col = [...table.querySelectorAll('thead th')].findIndex(th => /title/i.test(th.innerText))
    const td = row.children[col]
    const span = td.querySelector('[phx-click=open_card]')
    return {
      table: table.getBoundingClientRect().width,
      scroll: document.getElementById('table-scroll').clientWidth,
      cell: td.getBoundingClientRect().width,
      shown: span.clientWidth,
      full: span.scrollWidth,
    }
  }, id)
  console.log(JSON.stringify(m))

  if (m.table > m.scroll + 1) fail(`the table overflows its scroller: ${m.table} > ${m.scroll}`)
  if (m.cell > m.table * 0.5) fail(`the title cell takes ${m.cell} of ${m.table}`)
  if (!(m.full > m.shown)) fail('the long title is not truncated')
  console.log('ok: the long title truncates and the Title column keeps to its share')
} finally {
  await browser.close()
}
