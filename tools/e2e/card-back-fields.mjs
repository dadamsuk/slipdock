// The browser half of tools/e2e/card-back-fields.sh (#1672).
//
//   node tools/e2e/card-back-fields.mjs <login-url> <base-url> <board-id> <card-id> [shots-dir]
//
// SURVEY=1 prints every field's computed style and asserts nothing.
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, card, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 3200 } })).newPage()
const shot = async (name) => {
  if (shots) await page.locator('#card-modal [data-modal-box], #card-modal .modal-box').first().screenshot({ path: `${shots}/${name}.png` })
    .catch(() => page.screenshot({ path: `${shots}/${name}.png` }))
}

// Every box a person types into or picks from on the card back, at rest.
// The Markdown editor is measured on its frame (.md-editor), since the
// textarea under it is hidden.
const survey = () =>
  page.evaluate(() => {
    const sel = [
      // A date field (#1720) is its box; the native input in it is hidden.
      'input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=file]):not([type=range]):not(.date-field-input)',
      'textarea',
      'select',
      '.md-editor',
      '[data-date-field]',
    ].join(',')
    return [...document.querySelectorAll('#card-modal ' + sel.split(',').join(', #card-modal '))]
      .filter((el) => el.offsetParent !== null)
      .map((el) => {
        const s = getComputedStyle(el)
        // The editor's words are in .cm-content; its box is the frame.
        const md = el.classList.contains('md-editor')
        const t = md ? getComputedStyle(el.querySelector('.cm-content')) : s
        return {
          what: el.id || el.getAttribute('name') || el.className.split(' ')[0],
          tag: el.tagName.toLowerCase(),
          field: md ? 'field' : [...el.classList].filter((c) => c.startsWith('field')).join(' '),
          border: `${s.borderTopWidth} ${s.borderTopStyle} ${s.borderTopColor}`,
          radius: s.borderTopLeftRadius,
          family: t.fontFamily.split(',')[0].replace(/"/g, ''),
          size: t.fontSize,
          leading: t.lineHeight,
          pad: `${s.paddingTop} ${s.paddingLeft}`,
          bg: s.backgroundColor,
          shadow: s.boxShadow === 'none' ? '' : 'shadow',
          height: Math.round(el.getBoundingClientRect().height),
        }
      })
  })

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/boards/${board}/cards/${card}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-modal #card-title')
  await shot('1-light-rest')

  // Open what is closed until asked for: the description editor and Repeat….
  await page.click('#card-description-view')
  await page.waitForSelector('#card-modal .md-editor')
  await page.click('#repeat-edit')
  await page.waitForSelector('#repeat-form')
  await page.waitForTimeout(300)
  await shot('2-light-open')

  const rows = await survey()
  if (process.env.SURVEY) {
    console.table(rows)
  }

  await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'))
  await page.waitForTimeout(200)
  await shot('3-dark-open')
  const dark = await survey()
  if (process.env.SURVEY) {
    console.table(dark)
    process.exit(0)
  }

  for (const [theme, list] of [['light', rows], ['dark', dark]]) {
    // Boxed fields: one border, one radius, one family, at one of two sizes.
    const boxed = list.filter((r) => /\bfield\b/.test(r.field) && !/field-bare/.test(r.field))
    const loose = list.filter((r) => !/\bfield\b/.test(r.field))
    if (loose.length) fail(`${theme}: not drawn as a field: ` + loose.map((r) => `${r.tag}#${r.what}`).join(', '))
    if (boxed.length < 15) fail(`${theme}: only ${boxed.length} boxed fields found`)

    for (const key of ['border', 'radius', 'family', 'bg', 'shadow']) {
      const seen = new Set(boxed.filter((r) => r.family !== 'JetBrainsMonoVariable' || key !== 'family').map((r) => r[key]))
      if (seen.size !== 1) {
        console.table(boxed.map((r) => ({ what: r.what, [key]: r[key] })))
        fail(`${theme}: fields disagree on ${key}: ${[...seen].join(' | ')}`)
      }
    }
    // 14px Inter; code values (field-mono) 13px mono, the same optical size.
    const wrong = boxed.filter((r) => r.size !== (r.family === 'JetBrainsMonoVariable' ? '13px' : '14px'))
    if (wrong.length) fail(`${theme}: off-scale text: ` + wrong.map((r) => `${r.what} ${r.size}`).join(', '))
    const short = boxed.filter((r) => r.tag !== 'textarea' && r.tag !== 'div' && r.height !== 28)
    if (short.length) fail(`${theme}: single-line fields not 28px: ` + short.map((r) => `${r.what} ${r.height}`).join(', '))
    const bare = list.filter((r) => /field-bare/.test(r.field) && !/rgba\(0, 0, 0, 0\)/.test(r.border))
    if (bare.length) fail(`${theme}: in-place fields drawn with a border: ` + bare.map((r) => r.what).join(', '))
    console.log(`ok: ${theme}: ${boxed.length} fields share one border, radius, font, surface and size`)
  }

  // Focus: the same ring on a plain input and on the Markdown editor.
  const ring = async (selector) => {
    await page.focus(selector)
    await page.waitForTimeout(150)
    return page.evaluate((s) => {
      const el = document.querySelector(s)
      const box = el.closest('.md-editor') || el
      const st = getComputedStyle(box)
      return `${st.borderTopColor} ${st.outlineStyle === 'none' ? st.boxShadow : st.outlineColor}`
    }, selector)
  }
  const a = await ring('#card-bar')
  const b = await ring('#card-modal .md-editor .cm-content')
  if (a !== b) fail(`focus differs: bar ${a} / description ${b}`)
  console.log('ok: a focused field and the focused description editor look the same')
} catch (e) {
  await shot('error')
  fail(e.stack || String(e))
} finally {
  await browser.close()
}
