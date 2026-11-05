// The browser half of tools/e2e/controls.sh (#1704): one look per control.
// On a person's panel in Users (checkboxes, #1739), Configuration (radios) and the card back (the
// Completed toggle), in light and dark:
//   - a checkbox is 16×16 with a 4px radius, and filled with the primary
//     when checked;
//   - a toggle that is on is filled with the primary, and one that is off
//     is not;
//   - a radio is round;
//   - so no two of them share a shape.
//
//   node tools/e2e/controls.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board, card] = process.argv.slice(2)
const fail = (w) => { throw new Error(w) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path, scheme) => {
  await page.emulateMedia({ colorScheme: scheme })
  await page.goto(base + path, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  // Read the end state, not a frame of daisyUI's 0.2s fade.
  await page.addStyleTag({ content: '*, *::before { transition: none !important; animation: none !important; }' })
}

// The first visible control of a kind, its box and colours, checked or
// not (set on the element itself, with no event, so nothing is saved).
const look = (sel, checked) => page.evaluate(([sel, checked]) => {
  const el = [...document.querySelectorAll(sel)].find((e) => e.offsetParent !== null)
  if (!el) return null
  el.checked = checked
  // Colours as rgb over base-100, whatever notation the style uses
  // (oklch for the token, oklab for a mix).
  const cv = document.createElement('canvas'); cv.width = cv.height = 1
  const cx = cv.getContext('2d', { willReadFrequently: true })
  const ground = getComputedStyle(document.body).getPropertyValue('--color-base-100')
  const rgb = (c) => {
    cx.fillStyle = ground; cx.fillRect(0, 0, 1, 1)
    cx.fillStyle = c; cx.fillRect(0, 0, 1, 1)
    return cx.getImageData(0, 0, 1, 1).data.slice(0, 3).join(',')
  }
  const primary = rgb(getComputedStyle(document.body).getPropertyValue('--color-primary'))
  const s = getComputedStyle(el)
  const r = el.getBoundingClientRect()
  return { w: r.width, h: r.height, radius: parseFloat(s.borderTopLeftRadius), bg: rgb(s.backgroundColor), border: rgb(s.borderTopColor), primary }
}, [sel, checked])

const results = {}
for (const scheme of ['light', 'dark']) {
  // The table only reads (#1739): the checkboxes are in the person panel.
  await open('/users', scheme)
  await page.locator('[id^=manage-]').first().click()
  await page.waitForSelector('#person-panel input.checkbox')
  const box = await look('#person-panel input.checkbox', false) ?? fail('no checkbox in the person panel')
  if (box.w !== 16 || box.h !== 16) fail(`${scheme}: checkbox is ${box.w}×${box.h}, not 16×16`)
  if (box.radius !== 4) fail(`${scheme}: checkbox radius ${box.radius}px, not 4px`)
  if (box.bg === box.primary) fail(`${scheme}: an unchecked checkbox is filled with the primary`)
  const ticked = await look('#person-panel input.checkbox', true)
  if (ticked.bg !== ticked.primary) fail(`${scheme}: a checked checkbox is ${ticked.bg}, not the primary ${ticked.primary}`)
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/controls-users-${scheme}.png` })

  await open('/config', scheme)
  const radio = await look('input.radio', true) ?? fail('no radio on Configuration')
  if (radio.radius < radio.w / 2) fail(`${scheme}: radio radius ${radio.radius}px on a ${radio.w}px box: not round`)
  if (radio.border !== radio.primary) fail(`${scheme}: a chosen radio's ring is ${radio.border}, not the primary`)

  await open(`/boards/${board}/cards/${card}`, scheme)
  const off = await look('input.toggle', false) ?? fail('no toggle on the card back')
  if (off.bg === off.primary) fail(`${scheme}: a toggle that is off is filled with the primary`)
  const on = await look('input.toggle', true)
  if (on.bg !== on.primary) fail(`${scheme}: a toggle that is on is ${on.bg}, not the primary ${on.primary}`)
  if (!(on.w > on.h * 1.5)) fail(`${scheme}: toggle ${on.w}×${on.h} is not a pill`)
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/controls-card-${scheme}.png` })

  // Three shapes: a square, a circle and a pill.
  const shapes = new Set([`${box.w}x${box.h}r${box.radius}`, `${radio.w}x${radio.h}r${radio.radius}`, `${on.w}x${on.h}r${on.radius}`])
  if (shapes.size !== 3) fail(`${scheme}: controls share a shape: ${[...shapes]}`)
  results[scheme] = { checkbox: box, radio, toggle: on }
}
console.log(`ok: ${JSON.stringify(results)}`)
await browser.close()
