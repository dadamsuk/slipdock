// The browser half of tools/e2e/file-picker.sh (#1722).
//
//   node tools/e2e/file-picker.mjs <login-url> <base-url> <dir with boards.json and boards.csv>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, dir] = process.argv.slice(2)
const shots = process.env.SHOTS
const failures = []
const check = (ok, what) => { if (!ok) failures.push(what); console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage()
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
const open = async (path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
}
// No file input on the page is drawn: each is hidden or 1px and clear.
const visibleNative = () => page.locator('input[type=file]').evaluateAll(els =>
  els.filter(el => { const r = el.getBoundingClientRect(); return r.width > 2 && r.height > 2 && getComputedStyle(el).opacity !== '0' }).length)

const picker = '#import-boards-file'
await open('/account/data')
check(await visibleNative() === 0, 'import: no native file input is drawn')
check(await page.locator(`${picker} [data-role=file-hint]`).innerText() === 'A Slipdock or Trello export (.json), up to 8 MB', 'import: says what it takes')
const zone = await page.locator(`${picker} .file-picker-zone`).evaluate(el => getComputedStyle(el).borderStyle)
check(zone === 'dashed', `import: the zone is dashed (${zone})`)
const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.locator(`${picker} label.btn`).click()])
check(!!chooser, 'import: Choose file opens the chooser')
await chooser.setFiles(`${dir}/boards.csv`)
await page.waitForSelector(`${picker} [data-role=file-error]`)
check((await page.locator(`${picker} [data-role=file-error]`).innerText()).includes("isn't accepted"), 'import: a .csv is refused with what is wanted')
if (shots) await page.screenshot({ path: `${shots}/file-picker-refused.png` })

await open('/account/data')
await page.locator(`${picker} input[type=file]`).setInputFiles(`${dir}/boards.json`)
await page.waitForSelector(`${picker} [data-role=file-name]`)
check(await page.locator(`${picker} [data-role=file-name]`).innerText() === 'boards.json', 'import: shows the name')
check(/\d/.test(await page.locator(`${picker} [data-role=file-size]`).innerText()), 'import: shows the size')
if (shots) await page.screenshot({ path: `${shots}/file-picker-chosen.png` })
await page.locator(`${picker} button[aria-label="Remove boards.json"]`).click()
await page.waitForTimeout(400)
check(!(await page.locator(`${picker} [data-role=file-name]`).count()), 'import: the × takes it back')
await page.locator(`${picker} input[type=file]`).setInputFiles(`${dir}/boards.json`)
await page.waitForSelector(`${picker} [data-role=file-name]`)
await page.locator('#import-boards button[type=submit]').click()
await page.waitForFunction(() => document.body.innerText.includes('came in'), null, { timeout: 15000 }).catch(() => {})
check((await page.locator('body').innerText()).includes('came in'), 'import: the export goes back in')

await open('/tools')
check(await visibleNative() === 0, 'tools: no native file input is drawn')
check(await page.locator('[data-file-picker]').count() >= 1, 'tools: a file picker')
if (shots) await page.screenshot({ path: `${shots}/file-picker-tools.png` })

await browser.close()
if (failures.length) { console.error(`\n${failures.length} failed`); process.exit(1) }
console.log('\nall passed')
