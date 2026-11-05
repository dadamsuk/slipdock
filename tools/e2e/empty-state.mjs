// The browser half of tools/e2e/empty-state.sh: a new account's pages, each
// empty, show `empty_state/1` in the variant it should, with its heading
// and the action it offers, and the action does what it says.
//
//   node tools/e2e/empty-state.mjs <login-url> <base-url> <board-id> <page-slug> <empty-board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, board, slug, bare] = process.argv.slice(2)
const shots = process.env.SHOTS
const before = process.env.BEFORE === '1'
const fail = (w) => { throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

// [name, path, selector of the empty state, variant, heading, action text or null, element to screenshot]
const pages = [
  ['favourites', '/favourites', '#favourites-empty', 'full', 'Nothing favourited yet', null, 'main'],
  ['tidy', `/boards/${board}/tidy`, '#garden-empty', 'full', 'Nothing to tidy', 'Look the board over', 'main'],
  ['tools-yours', '/tools', '#tools-yours-empty', 'compact', 'No Tools of yours yet', 'Publish a Tool', 'main'],
  ['tools-shared', '/tools', '#tools-shared-empty', 'compact', 'Nothing shared with you', null, null],
  ['tools-listed', '/tools', '#tools-listed-empty', 'compact', 'None listed on this server', null, null],
  ['groups', '/groups', '#groups-empty', 'full', 'No groups yet', 'Create group', 'main'],
  ['tokens', '/account/tokens', '#tokens-empty', 'compact', 'No tokens yet', 'Create token', 'main'],
  ['passkeys', '/account/sign-in', '#passkeys-empty', 'compact', 'No passkeys yet', 'Add a passkey', '#passkeys'],
  ['activity', `/boards/${board}/activity`, '#activity-empty', 'compact', 'Nothing has happened yet', null, '#activity-modal'],
  ['history', `/boards/${board}/wiki/${slug}/history`, '#history-empty', 'full', 'No versions yet', null, 'main'],
  ['signups', '/users/signups', '#signups-empty', 'compact', 'Nobody is waiting', null, 'main'],
  ['wiki', `/boards/${bare}/wiki`, '#wiki-empty', 'full', 'No pages yet', 'Write the first one', 'main'],
  ['templates', '/templates', '#templates-empty', 'full', 'No templates yet', null, 'main'],
  ['rules', `/boards/${bare}/automations`, '#rules-empty', 'compact', 'No rules yet', null, '#automations-modal'],
  ['aging', `/boards/${bare}/visualise`, '#aging-empty', 'compact', 'Nothing in progress', null, '#aging'],
  ['mix', `/boards/${bare}/visualise`, '#mix-empty', 'compact', 'No tags yet', null, '#mix'],
  ['runners', `/boards/${bare}/visualise`, '#runners-empty', 'compact', 'No runners', 'Set one up in Automations', '#runners'],
  ['jobs', `/boards/${board}/visualise`, '#jobs-empty', 'compact', 'No jobs yet', null, '#runners'],
]
const results = []
for (const [name, path, sel, variant, heading, action, shot] of pages) {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(300)
  if (shots && shot) {
    const target = shot === 'main' ? page : page.locator(shot).first()
    await target.screenshot({ path: `${shots}/${before ? 'before' : 'after'}-${name}.png` })
  }
  if (before) continue
  const el = page.locator(sel)
  if (await el.count() !== 1) fail(`${name}: ${sel} not shown`)
  if (await el.getAttribute('data-empty-state') !== variant) fail(`${name}: not the ${variant} variant`)
  if (!(await el.locator('h2, h3').first().innerText()).includes(heading)) fail(`${name}: heading isn't "${heading}"`)
  const icon = el.locator('span[class*=hero-]').first()
  if (!(await icon.isVisible())) fail(`${name}: no icon`)
  const tint = await icon.evaluate((n) => getComputedStyle(n.parentElement).backgroundColor)
  if (tint === 'rgba(0, 0, 0, 0)') fail(`${name}: the icon's square isn't tinted`)
  const act = el.locator('[data-role=empty-state-action]')
  if (action) {
    if (!(await act.innerText()).includes(action)) fail(`${name}: no "${action}" action`)
  } else if (await act.count()) fail(`${name}: an action it shouldn't have`)
  results.push(name)
}

if (!before) {
  // Create group puts the cursor in the new group's name.
  await page.goto(`${base}/groups`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.locator('#groups-empty [data-role=empty-state-action] label').click()
  if (await page.evaluate(() => document.activeElement?.id) !== 'new-group-name') fail('Create group did not focus the name')
  // Create token makes one, and the empty state goes.
  await page.goto(`${base}/account/tokens`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.locator('#tokens-empty [data-role=empty-state-action] button').click()
  await page.locator('#new-token').waitFor()
  if (await page.locator('#tokens-empty').count()) fail('the tokens empty state stayed after Create token')
  // Write the first one opens a new page.
  await page.goto(`${base}/boards/${bare}/wiki`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.locator('#wiki-empty [data-role=empty-state-action] a').click()
  await page.waitForURL(`**/boards/${bare}/wiki/new`)
  results.push('actions')
}
console.log(before ? 'ok: before shots taken' : `ok: ${results.join(', ')}`)
await browser.close()
