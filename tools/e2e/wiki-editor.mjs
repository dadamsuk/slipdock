// The browser half of tools/e2e/wiki-editor.sh.
//
//   node tools/e2e/wiki-editor.mjs <login-url> <base-url> <kb-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } })
const open = async (slug) => {
  await page.goto(`${base}/boards/${kb}/wiki/${slug}/edit`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('.md-editor-page')
  await page.waitForTimeout(300)
}
const width = (sel) => page.$eval(sel, (el) => el.getBoundingClientRect().width)
const pressed = () => page.getAttribute('#toggle-preview', 'aria-pressed')

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // 1. One pane, the whole width.
  await open('plain-notes')
  if (shots) await page.screenshot({ path: `${shots}/wiki-editor.png` })
  if (await page.isVisible('#page-preview')) fail('the Preview pane should start off')
  if ((await pressed()) !== 'false') fail('Preview should start unpressed')
  const editor = await width('.md-editor-page')
  const form = await width('#page-form')
  if (editor < form * 0.95) fail(`the editor is ${editor}px of a ${form}px form: not the whole width`)
  console.log(`ok: one pane, ${Math.round(editor)}px of ${Math.round(form)}px`)

  // The toggle puts the pane beside it, and the browser remembers.
  await page.click('#toggle-preview')
  await page.waitForSelector('#page-preview', { state: 'visible' })
  if ((await width('.md-editor-page')) > form * 0.6) fail('with the preview on, the editor should halve')
  if (!(await page.textContent('#page-preview')).includes('Notes')) fail('the preview should show the page')
  await open('plain-notes')
  await page.waitForSelector('#page-preview', { state: 'visible' })
  if ((await pressed()) !== 'true') fail('Preview on should be remembered across a reload')
  console.log('ok: Preview turns the pane on, and is remembered')
  await page.click('#toggle-preview')
  await page.waitForSelector('#page-preview', { state: 'detached' })
  await open('plain-notes')
  if (await page.isVisible('#page-preview')) fail('Preview off should be remembered too')
  console.log('ok: Preview off is remembered')

  // 2. Encryption in the ⋯ menu on an ordinary page.
  if (await page.isVisible('[data-meld-action=encrypt]')) fail('Encrypt should be out of sight until the menu opens')
  await page.click('#editor-menu')
  await page.waitForSelector('#editor-menu-items [data-meld-action=encrypt]', { state: 'visible' })
  for (const a of ['whole', 'edit']) {
    if (!(await page.isVisible(`#editor-menu-items [data-meld-action=${a}]`))) fail(`${a} missing from the menu`)
  }
  await page.waitForTimeout(400) // the menu fades in
  if (shots) await page.screenshot({ path: `${shots}/wiki-editor-menu.png` })
  // The menu's Encrypt still reaches the MeldEditor hook: its dialog opens.
  await page.click('#editor-menu-items [data-meld-action=encrypt]')
  await page.waitForSelector('#meld-dialog[open]', { timeout: 5000 })
  await page.keyboard.press('Escape')
  console.log('ok: encryption is in the ⋯ menu, and Encrypt there opens its dialog')

  // …and in the row on an encrypted page.
  await open('vaulted')
  if (await page.locator('#editor-menu').count()) fail('an encrypted page should not hide the actions in a menu')
  for (const a of ['encrypt', 'whole', 'edit']) {
    if (!(await page.isVisible(`#meld-tools > [data-meld-action=${a}]`))) fail(`${a} should be in the row`)
  }
  console.log('ok: on an encrypted page the actions stand in the row')

  // 3. The button hierarchy: Save solid primary, Cancel and Preview tertiary.
  const look = (sel) => page.$eval(sel, (el) => {
    const cs = getComputedStyle(el); return { bg: cs.backgroundColor, color: cs.color, border: cs.borderTopColor }
  })
  const save = await look('#save-page')
  const cancel = await look('#cancel-edit')
  const preview = await look('#toggle-preview')
  if (save.bg === cancel.bg) fail('Save should be solid, Cancel not: ' + JSON.stringify({ save, cancel }))
  if (cancel.bg !== preview.bg) fail('Cancel and Preview should be the same tertiary: ' + JSON.stringify({ cancel, preview }))
  if (!/^rgba\(0, 0, 0, 0\)$|transparent/.test(cancel.bg)) fail('Cancel should be a ghost: ' + cancel.bg)
  console.log('ok: Save is the solid primary, Cancel and Preview ghost')
} catch (e) {
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
