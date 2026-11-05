// The browser half of tools/e2e/tree-names.sh (#1594).
//
//   node tools/e2e/tree-names.mjs <login-url> <base-url> <board-id> <cards-id> <folder-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, cards, folder] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }
const full = 'Agent supervision 5/9: parked jobs must be released on timeout, and everybody told about it'

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

// The name's span: what it holds, how it is drawn, and how it fits.
const measure = (locator) => locator.evaluate((el) => {
  const style = getComputedStyle(el)
  return {
    text: el.textContent.trim(),
    clipped: el.scrollWidth > el.clientWidth,
    overflow: style.overflowX,
    ending: style.textOverflow,
    width: el.getBoundingClientRect().width,
  }
})

const open = async () => {
  await page.goto(`${base}/boards/${kb}/wiki`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const row = page.locator(`.wt-row[data-key="folder:${cards}"]`)
  await row.waitFor()
  if ((await row.getAttribute('aria-expanded')) !== 'true') await row.locator('[data-toggle]').click()
  const card = page.locator(`.wt-row[data-key="folder:${folder}"]`)
  await card.waitFor()
  return card
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // Full titles: the whole name is on the page, and CSS shortens it.
  let row = await open()
  let name = row.locator('a span.truncate')
  let seen = await measure(name)
  if (seen.text !== full) fail(`the server cut it: ${seen.text}`)
  if (!seen.clipped) fail('the long name was not clipped: it fits, or the row grew')
  if (seen.overflow !== 'hidden' || seen.ending !== 'ellipsis') fail(`drawn as ${seen.overflow}/${seen.ending}`)
  if (seen.width > 320) fail(`the tree grew to ${seen.width}px to hold it`) // its default (#1745)
  if ((await row.locator('a').first().getAttribute('title')) !== full) fail('no full name on hover')
  console.log('ok: a long title is shortened by CSS, whole in the DOM and on hover')

  // The header's button: short names, the title kept on hover.
  await page.locator('#wiki-tree-names').click()
  await page.waitForSelector('#wiki-tree-names[aria-pressed="true"]')
  await page.waitForFunction((key) => {
    const el = document.querySelector(`.wt-row[data-key="${key}"] a span.truncate`)
    return el && el.textContent.trim() === 'Parked jobs'
  }, `folder:${folder}`)
  row = page.locator(`.wt-row[data-key="folder:${folder}"]`)
  if ((await row.locator('a').first().getAttribute('title')) !== full) fail('hover lost the title')
  seen = await measure(row.locator('a span.truncate'))
  if (seen.clipped) fail('a short name should fit')
  console.log('ok: the button shows the short name, the title still on hover')

  // It stays after a reload, being the person's.
  row = await open()
  if ((await row.locator('a span.truncate').innerText()).trim() !== 'Parked jobs') fail('not kept')

  // Breadcrumbs: a long name is clipped, not wrapped away.
  await page.locator('#wiki-tree-names').click()
  await page.waitForSelector('#wiki-tree-names[aria-pressed="false"]')
  await page.goto(`${base}/boards/${kb}/wiki?folder=${folder}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const crumb = page.locator(`#wiki-main nav span.truncate[title="${full}"]`).first()
  seen = await measure(crumb)
  if (seen.text !== full || !seen.clipped) fail(`breadcrumb: ${JSON.stringify(seen)}`)
  console.log('ok: a breadcrumb is shortened by CSS too')

  await page.locator('#wiki-tree-names').click()
  await page.waitForSelector('#wiki-tree-names[aria-pressed="true"]')
} finally {
  await browser.close()
}
