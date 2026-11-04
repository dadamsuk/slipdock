// The browser half of tools/e2e/fonts.sh (#1705, W-2307).
//
//   node tools/e2e/fonts.mjs <login-url> <base-url> <board-id> <card-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board, card] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (w) => { throw new Error(w) }

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async (path) => {
  await page.goto(base + path, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.evaluate(() => document.fonts.ready)
}

// The first family an element asks for, its weight, and whether the face
// behind it has loaded (document.fonts), so a missing file fails here
// rather than quietly falling back.
const face = (sel) => page.evaluate(async (sel) => {
  const el = [...document.querySelectorAll(sel)].find((e) => e.offsetParent !== null)
  if (!el) return null
  const s = getComputedStyle(el)
  const family = s.fontFamily.split(',')[0].replace(/["']/g, '').trim()
  await document.fonts.load(`${s.fontWeight} ${s.fontSize} "${family}"`, el.textContent || 'a')
  const loaded = [...document.fonts].some((f) => f.family.replace(/["']/g, '') === family && f.status === 'loaded')
  return { family, weight: s.fontWeight, size: s.fontSize, spacing: s.letterSpacing, loaded }
}, sel)

// A page title: Sora 600, slightly tight.
await open('/work')
const title = await face('h1.page-title') ?? fail('no h1.page-title on My work')
if (title.family !== 'SoraVariable') fail(`page title is ${title.family}, not Sora`)
if (title.weight !== '600') fail(`page title weight ${title.weight}, not 600`)
if (!title.loaded) fail('Sora did not load from /fonts')
if (title.size !== '28px') fail(`page title is ${title.size} at 1440, not 28px`)
console.log(`ok: My work's title is Sora ${title.weight} at ${title.size}, loaded`)
const body = await page.evaluate(() => ({
  family: getComputedStyle(document.body).fontFamily.split(',')[0].replace(/["']/g, ''),
  features: getComputedStyle(document.body).fontFeatureSettings,
}))
if (body.family !== 'InterVariable') fail(`body is ${body.family}, not Inter`)
if (/cv11/.test(body.features)) fail(`body still sets cv11: ${body.features}`)
console.log(`ok: body is Inter with ${body.features}`)
if (shots) await page.screenshot({ path: `${shots}/fonts-work.png` })

// Code values on the board and the card back: JetBrains Mono.
await open(`/boards/${board}/cards/${card}`)
for (const sel of ['.font-mono', 'code']) {
  const mono = await face(sel)
  if (!mono) continue
  if (mono.family !== 'JetBrainsMonoVariable') fail(`${sel} is ${mono.family}, not JetBrains Mono`)
  if (!mono.loaded) fail(`JetBrains Mono did not load for ${sel}`)
  console.log(`ok: ${sel} is JetBrains Mono, loaded`)
}
// The field class too, on a field made for the check (not every card shows one).
const field = await page.evaluate(() => {
  const el = document.createElement('input'); el.className = 'field field-mono'; el.value = 'lib/**'
  document.body.appendChild(el)
  const f = getComputedStyle(el).fontFamily.split(',')[0].replace(/["']/g, '')
  el.remove(); return f
})
if (field !== 'JetBrainsMonoVariable') fail(`field-mono is ${field}`)
console.log('ok: field-mono is JetBrains Mono')
const loadedFaces = await page.evaluate(() => [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family.replace(/["']/g, '')))
for (const f of ['InterVariable', 'JetBrainsMonoVariable']) {
  if (!loadedFaces.includes(f)) fail(`${f} not loaded on the card back: ${loadedFaces.join(', ')}`)
}
if (shots) await page.screenshot({ path: `${shots}/fonts-card.png` })
await browser.close()
console.log('PASS fonts')
