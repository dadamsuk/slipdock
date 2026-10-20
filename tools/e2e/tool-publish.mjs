// The browser half of tools/e2e/tool-publish.sh.
//
//   node tools/e2e/tool-publish.mjs <login-url> <base-url> <work-dir>
import { createRequire } from 'node:module'
import path from 'node:path'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, work] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 1400, height: 900 }, acceptDownloads: true })
const page = await context.newPage()

async function open(url) {
  await page.goto(`${base}${url}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

// Chooses the file, waits for it to finish uploading, then submits.
async function publish(form, file) {
  await page.locator(`${form} input[type=file]`).setInputFiles(path.join(work, file))
  await page.locator(`${form} button[type=submit]:not([disabled])`).waitFor({ timeout: 10000 })
    .catch(() => fail(`the button never enabled for ${file}`))
  await page.locator(`${form} button[type=submit]`).click()
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // Something that isn't a package says why, and the page stays put.
  await open('/tools')
  await publish('#tools-publish-form', 'notes.tgz')
  await page.locator('#tools-publish-form-error', { hasText: 'not a readable .tar.gz' }).waitFor({ timeout: 5000 })
    .catch(() => fail('a junk file showed no error'))
  console.log('ok: a file that is not a package is refused with the reason')

  // A new Tool from the gallery opens on its own page.
  await open('/tools')
  await publish('#tools-publish-form', 'job-scan-1.0.0.tgz')
  await page.waitForURL(`${base}/tools/job-scan?version=1.0.0`, { timeout: 10000 })
    .catch(() => fail(`publishing landed on ${page.url()}`))
  await page.locator('#tool-header', { hasText: 'version 1.0.0' }).waitFor()
  await page.locator('#tool-skill-job-scan-setup').waitFor().catch(() => fail('its skills are not shown'))
  console.log('ok: the gallery published job-scan 1.0.0 and opened its page')

  // Its package comes back as a download.
  await page.waitForSelector('.phx-connected')
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.locator('#tool-package-download').click(),
  ])
  if (download.suggestedFilename() !== 'job-scan-1.0.0.tar.gz') fail(`downloaded ${download.suggestedFilename()}`)
  await download.saveAs(path.join(work, 'downloaded.tar.gz'))
  console.log('ok: Download the package saved job-scan-1.0.0.tar.gz')

  // The same version again is refused on the Tool's page; the next one is taken.
  await publish('#tool-publish-form', 'job-scan-1.0.0.tgz')
  await page.locator('#tool-publish-form-error', { hasText: 'already published' }).waitFor({ timeout: 5000 })
    .catch(() => fail('republishing 1.0.0 showed no error'))
  console.log('ok: the same version again is refused')

  await publish('#tool-publish-form', 'job-scan-1.0.1.tgz')
  await page.waitForURL(`${base}/tools/job-scan?version=1.0.1`, { timeout: 10000 })
    .catch(() => fail(`the new version landed on ${page.url()}`))
  await page.locator('#tool-header', { hasText: 'version 1.0.1' }).waitFor({ timeout: 5000 })
    .catch(() => fail('the page does not show 1.0.1'))
  await page.locator('#tool-versions', { hasText: '1.0.0' }).waitFor()
    .catch(() => fail('the version list has no 1.0.0'))
  if (await page.locator('#tool-publish-form-error').count()) fail('the old error is still shown')
  console.log('ok: the Tool page published 1.0.1 and shows it, with 1.0.0 still listed')
} finally {
  await browser.close()
}
