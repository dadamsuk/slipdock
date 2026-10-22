// The browser half of tools/e2e/page-dress.sh (#1203): on a page's editor,
// an icon picked and then a colour picked are both still picked once the
// form's round trip is back, and both are saved.
//
//   node tools/e2e/page-dress.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb] = process.argv.slice(2)

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

const fail = async (why) => {
  console.error('FAIL: ' + why)
  await page.screenshot({ path: '/tmp/page-dress-failure.png', fullPage: true })
  await browser.close()
  process.exit(1)
}

const radio = (field, value) => page.locator(`#page-dress input[name="page[${field}]"][value="${value}"]`)
const pick = (field, value) => page.locator(`#page-dress label:has(input[name="page[${field}]"][value="${value}"])`).click()
// A pick goes to the server as the form's change and comes back as a render.
const settle = () => page.waitForTimeout(800)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${kb}/wiki/acme-call/edit`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.locator('#page-dress').waitFor()

  await pick('icon', 'briefcase')
  await settle()
  if (!(await radio('icon', 'briefcase').isChecked())) await fail('the icon is not picked once the form comes back')

  await pick('color', 'amber')
  await settle()
  if (!(await radio('color', 'amber').isChecked())) await fail('the colour is not picked once the form comes back')
  if (!(await radio('icon', 'briefcase').isChecked())) await fail('picking a colour reset the icon')
  console.log('ok: the icon survives picking a colour')

  await pick('icon', 'star')
  await settle()
  if (!(await radio('color', 'amber').isChecked())) await fail('picking an icon reset the colour')
  await pick('icon', 'briefcase')
  await settle()
  console.log('ok: the colour survives picking an icon')

  await page.locator('#page-form button[type=submit]').first().click()
  await page.waitForURL((u) => !u.pathname.endsWith('/edit'), { timeout: 5000 })
  console.log('ok: saved')
} catch (e) {
  await fail(e.message)
}
await browser.close()
