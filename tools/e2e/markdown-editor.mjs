// The browser half of tools/e2e/markdown-editor.sh: the Markdown editor over
// a wiki page's body, a card's description and its comment box.
//
//   node tools/e2e/markdown-editor.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, card] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })
const errors = []
// The sign-in page's own hooks can push into a socket the redirect is
// tearing down; only errors on the pages under test count.
page.on('pageerror', (e) => { if (!page.url().includes('/login')) errors.push(`${e.message} @ ${page.url()}`) })

// A 1×1 PNG, pasted as a screenshot would be.
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

async function pasteImage(selector) {
  await page.evaluate(([sel, data]) => {
    const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0))
    const transfer = new DataTransfer()
    transfer.items.add(new File([bytes], 'image.png', { type: 'image/png' }))
    const event = new ClipboardEvent('paste', { clipboardData: transfer, bubbles: true, cancelable: true })
    document.querySelector(sel).dispatchEvent(event)
  }, [selector, PNG])
}

// SHOTS=<dir> keeps a picture of each editor, in light and dark, to look at.
async function shot(name) {
  if (!process.env.SHOTS) return
  for (const theme of ['light', 'dark']) {
    await page.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
    await page.screenshot({ path: `${process.env.SHOTS}/${name}-${theme}.png` })
  }
  await page.evaluate(() => document.documentElement.removeAttribute('data-theme'))
}

// Dropping an image from the desktop, as the desktop does it: trusted drag
// events from Chrome itself, carrying a real file (by default a screenshot
// written here) — a DragEvent made in the page is not the same thing.
async function dropImage(selector, file) {
  const box = await page.locator(selector).boundingBox()
  const x = box.x + 40
  const y = box.y + 12
  if (!file) {
    file = `${mkdtempSync(`${tmpdir()}/md-drop-`)}/Screenshot 2026-10-14 at 19.20.00.png`
    await page.screenshot({ path: file })
  }
  const cdp = await page.context().newCDPSession(page)
  const data = { items: [], files: [file], dragOperationsMask: 1 }
  for (const type of ['dragEnter', 'dragOver', 'drop']) {
    await cdp.send('Input.dispatchDragEvent', { type, x, y, data })
  }
}

const lineText = (scope, n) => page.locator(`${scope} .cm-line`).nth(n).innerText()

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // --- The wiki page's body ---------------------------------------------
  await page.goto(`${base}/boards/${kb}/wiki/acme-call/edit`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const body = '[id^=page-body-editor] .md-editor'
  await page.locator(`${body} .cm-content`).waitFor()
  if (await page.locator('#page_body').isVisible()) fail('the page body textarea is still showing')

  await page.locator(`${body} .cm-content`).click()
  await page.keyboard.press('Control+End')
  await page.keyboard.type('\n\n# Plan **now**\n\nnext line')
  // The caret is on "next line": the heading above shows rendered.
  const heading = page.locator(`${body} .cm-line.cm-atomic-h1`)
  await heading.waitFor()
  const rendered = await heading.innerText()
  if (rendered.includes('#') || rendered.includes('**')) fail(`heading not rendered off its line: ${JSON.stringify(rendered)}`)
  // Back on the heading, its Markdown shows again.
  await heading.click()
  await page.waitForTimeout(300)
  const raw = await heading.innerText()
  if (!raw.includes('# Plan **now**')) fail(`heading source not shown on its line: ${JSON.stringify(raw)}`)
  console.log('ok: the page body renders lines off the caret and shows the source on it')
  await shot('wiki')

  // The textarea the form sends has what was typed.
  const sent = await page.locator('#page_body').inputValue()
  if (!sent.includes('# Plan **now**\n\nnext line')) fail(`textarea not kept in step: ${JSON.stringify(sent)}`)

  // Pasting an image: the placeholder goes in through the textarea, and the
  // upload's Markdown takes its place, in the editor too.
  await page.keyboard.press('Control+End')
  await pasteImage(`${body} .cm-content`)
  await page.waitForFunction(() => {
    const v = document.getElementById('page_body').value
    return v.includes('/attachments/') && !v.includes('Uploading')
  }, null, { timeout: 15000 })
  const editorText = await page.evaluate(() => document.getElementById('page_body').markdownEditor.view.state.doc.toString())
  if (!editorText.includes('/attachments/')) fail('the uploaded image never reached the editor')
  console.log('ok: a pasted image is uploaded and linked in the editor')

  // Dropping one does the same.
  const before = (await page.locator('#page_body').inputValue()).split('/attachments/').length
  await dropImage(`${body} .cm-content`)
  await page.waitForFunction((n) => {
    const v = document.getElementById('page_body').value
    return v.split('/attachments/').length > n && !v.includes('Uploading')
  }, before, { timeout: 15000 }).catch(async () =>
    fail(`a dropped image was not uploaded: ${JSON.stringify(await page.locator('#page_body').inputValue())}`))
  const inEditor = await page.evaluate(() => document.getElementById('page_body').markdownEditor.view.state.doc.toString())
  if (inEditor !== (await page.locator('#page_body').inputValue())) fail('the editor and the textarea disagree after a drop')
  console.log('ok: a dropped image is uploaded and linked in the editor')

  // A photo straight off a camera (20 MB, over the old 10 MB limit) goes up.
  const photo = `${mkdtempSync(`${tmpdir()}/md-drop-`)}/IMG_1234.png`
  writeFileSync(photo, Buffer.concat([Buffer.from(PNG, 'base64'), Buffer.alloc(20_000_000)]))
  const upTo = (await page.locator('#page_body').inputValue()).split('/attachments/').length
  await dropImage(`${body} .cm-content`, photo)
  await page.waitForFunction((n) => {
    const v = document.getElementById('page_body').value
    return v.split('/attachments/').length > n && v.includes('IMG_1234.png') && !v.includes('Uploading')
  }, upTo, { timeout: 60000 }).catch(() => fail('a 20 MB photo was not uploaded'))
  console.log('ok: a 20 MB photo is uploaded')

  // One the upload refuses (over 50 MB) is taken out again with a reason,
  // and doesn't stop the page saving — LiveView won't submit a form that
  // still holds an upload error.
  const big = `${mkdtempSync(`${tmpdir()}/md-drop-`)}/holiday photo.png`
  writeFileSync(big, Buffer.concat([Buffer.from(PNG, 'base64'), Buffer.alloc(51_000_000)]))
  const kept = await page.locator('#page_body').inputValue()
  await dropImage(`${body} .cm-content`, big)
  await page.getByText('holiday photo.png is too large').first()
    .waitFor({ timeout: 10000 }).catch(() => fail('no message for an image that is too large'))
  await page.waitForFunction((v) => document.getElementById('page_body').value === v, kept, { timeout: 5000 })
    .catch(async () => fail(`the refused image left its placeholder: ${JSON.stringify(await page.locator('#page_body').inputValue())}`))
  console.log('ok: a dropped image that is too large is refused with a reason, placeholder and all')

  await page.locator('#page-form button[type=submit]', { hasText: 'Save' }).first().click()
  await page.waitForURL(/\/wiki\/acme-call$/)
  console.log('ok: the page saved')

  // --- The card's description -------------------------------------------
  await page.goto(`${base}/boards/${kb}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.getByText('Add more detail…').first().click()
  const desc = `#card-description-editor-${card} .md-editor`
  await page.locator(`${desc} .cm-content`).waitFor()
  // It opens with the caret in it.
  await page.waitForFunction((sel) => document.querySelector(sel)?.contains(document.activeElement), `${desc} .cm-content`)
  await page.keyboard.type('**Bold** move\n\n- [ ] a task\n- [x] done')
  await page.keyboard.press('ArrowUp')
  await page.keyboard.press('ArrowUp')
  await page.keyboard.press('ArrowUp')
  await shot('description')
  await page.keyboard.press('Control+a')
  await page.keyboard.type('**Bold** move')
  await page.waitForTimeout(1000)
  await page.keyboard.press('Escape')
  // Escape is the description's own (stop editing), not the card's (close).
  await page.locator('#card-description-view', { hasText: 'Bold** move' }).waitFor({ timeout: 5000 })
    .catch(() => fail('Escape did not stop editing the description'))
  if (await page.locator(desc).count()) fail('the description editor is still open')
  if (!(await page.locator('#board-card #card-form').count())) fail('Escape closed the card as well')
  console.log('ok: the description is typed, and Escape stops editing it without closing the card')

  // --- The comment box ----------------------------------------------------
  const comment = '#comment-editor-0 .md-editor'
  await page.locator(`${comment} .cm-content`).click()
  await page.keyboard.type('Ping @e2e')
  const menu = page.locator('ul.menu.fixed:not(.hidden) a').first()
  await menu.waitFor({ timeout: 3000 }).catch(() => fail('no @mention menu from the editor'))
  await page.keyboard.press('Enter')
  await page.keyboard.type('ok')
  const typed = await page.locator('#comment-editor-0 textarea').inputValue()
  if (!/^Ping @\S+ ok$/.test(typed)) fail(`mention not taken into the comment: ${JSON.stringify(typed)}`)
  await page.locator('#add-comment-0 button[type=submit]').click()
  await page.locator('#comment-editor-1 .md-editor .cm-content').waitFor()
  const fresh = await page.evaluate(() => document.querySelector('#comment-editor-1 textarea').markdownEditor.view.state.doc.toString())
  if (fresh.trim() !== '') fail(`the comment box kept its text: ${JSON.stringify(fresh)}`)
  console.log('ok: an @mention is picked in the comment box, and posting it starts a fresh editor')

  // An empty comment is not sent; the editor gets the focus instead.
  await page.locator('#add-comment-1 button[type=submit]').click()
  await page.waitForFunction(() => document.querySelector('#comment-editor-1 .cm-content')?.contains(document.activeElement))
  console.log('ok: an empty comment is held back and the editor focused')

  if (errors.length) fail(`page errors: ${errors.join('; ')}`)
} catch (e) {
  await page.screenshot({ path: '/tmp/markdown-editor-failure.png' })
  console.error('FAIL: ' + e.message + ' (screenshot: /tmp/markdown-editor-failure.png)')
  process.exitCode = 1
} finally {
  await browser.close()
}
