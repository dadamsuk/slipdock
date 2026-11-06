// The browser half of tools/e2e/help-flow.sh: Help › How work flows (#1885),
// signed out, at desktop and phone width, light and dark.
//
//   node tools/e2e/help-flow.mjs <base-url>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [base] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (w) => { throw new Error(w) }
const ok = (w) => console.log(`ok: ${w}`)

const stages = ['1. Writing the card', '2. Queued and claimed', '3. Building', '4. Shipping',
  '5. Submitting', '6. Verifying', '7. Afterwards']
const ringed = ['writing', 'building', 'verifying', 'afterwards']

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await context.newPage()
const open = async (path) => {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(200)
}
const snap = async (name, fullPage = false) => {
  if (shots) await page.screenshot({ path: `${shots}/${name}.png`, fullPage })
}
const noSideScroll = async (where) => {
  const over = await page.evaluate(() => {
    const doc = document.documentElement
    const help = document.getElementById('help')
    const flow = document.getElementById('help-flow')
    const right = help.getBoundingClientRect().right
    const past = [...flow.querySelectorAll('*')].filter((e) => e.getBoundingClientRect().right > right + 1).length
    return { doc: doc.scrollWidth - doc.clientWidth, help: help.scrollWidth - help.clientWidth, past }
  })
  if (over.doc > 0 || over.help > 0 || over.past > 0) fail(`${where}: sideways (${JSON.stringify(over)})`)
}
// WCAG contrast of an element's text against the colour behind it.
const contrast = (sel) => page.$eval(sel, (el) => {
  const rgb = (c) => {
    const ctx = document.createElement('canvas').getContext('2d')
    ctx.fillStyle = c; ctx.fillRect(0, 0, 1, 1)
    const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data
    return [r, g, b, a / 255]
  }
  const bgOf = (e) => {
    const layers = []
    for (let n = e; n; n = n.parentElement) {
      const c = rgb(getComputedStyle(n).backgroundColor)
      if (c[3] > 0) layers.push(c)
      if (c[3] >= 1) break
    }
    return layers.reverse().reduce((acc, [r, g, b, a]) =>
      [acc[0] * (1 - a) + r * a, acc[1] * (1 - a) + g * a, acc[2] * (1 - a) + b * a], [255, 255, 255])
  }
  const lum = ([r, g, b]) => {
    const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4 }
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
  }
  const bg = bgOf(el)
  const [r, g, b, a] = rgb(getComputedStyle(el).color)
  const fg = [bg[0] * (1 - a) + r * a, bg[1] * (1 - a) + g * a, bg[2] * (1 - a) + b * a]
  const [l1, l2] = [lum(fg), lum(bg)].sort((x, y) => y - x)
  return (l1 + 0.05) / (l2 + 0.05)
})

for (const scheme of ['light', 'dark']) {
  await page.emulateMedia({ colorScheme: scheme })
  for (const [w, h, label] of [[1440, 900, 'desktop'], [390, 844, 'phone']]) {
    const where = `${label} ${scheme}`
    await page.setViewportSize({ width: w, height: h })

    // The three ways to it.
    await open('/help/agents')
    await page.click('#help-flow-link')
    await page.waitForSelector('#help-flow')
    await open('/help/agents/runners')
    await page.click('#help-runners-flow')
    await page.waitForSelector('#help-flow')
    await open('/help')
    await page.click('#help-hub-agents-flow')
    await page.waitForSelector('#help-flow')
    if (!page.url().endsWith('/help/agents/flow')) fail(`${where}: landed on ${page.url()}`)
    const theme = await page.evaluate(() => document.documentElement.getAttribute('data-theme'))
    if (theme !== scheme) fail(`${where}: data-theme is ${theme}`)
    ok(`${where}: the agents index, Runners and the hub link to it`)

    const heads = await page.$$eval('#help-flow section[id^="flow-"] h2', (hs) =>
      hs.map((h) => h.textContent.trim()).filter((t) => /^\d\. /.test(t)))
    if (JSON.stringify(heads) !== JSON.stringify(stages)) fail(`${where}: stages ${heads}`)
    ok(`${where}: the seven stages in order`)

    // The diagram: one column, top to bottom, the person's nodes ringed.
    const nodes = await page.$$eval('#flow-diagram ol > li', (ls) => ls.map((l) => {
      const r = l.getBoundingClientRect()
      const box = l.firstElementChild
      return { id: l.id, top: r.top, left: r.left, person: box.dataset.person === 'true',
               ring: getComputedStyle(box).boxShadow !== 'none' }
    }))
    if (nodes.length !== 7) fail(`${where}: ${nodes.length} nodes`)
    nodes.forEach((n, i) => {
      if (i && n.top <= nodes[i - 1].top) fail(`${where}: ${n.id} isn't below the one before`)
      if (Math.abs(n.left - nodes[0].left) > 1) fail(`${where}: ${n.id} is out of the column`)
    })
    const rung = nodes.filter((n) => n.person && n.ring).map((n) => n.id.replace('flow-node-', ''))
    if (JSON.stringify(rung) !== JSON.stringify(ringed)) fail(`${where}: ringed ${rung}`)
    ok(`${where}: the diagram is a column of 7, ringed at ${rung.join(', ')}`)

    // Words stay readable on the ring's tint and on the actor chips.
    // Every chip on the page, then the words on the ringed tint.
    const chips = await page.$$eval('#help-flow .badge', (bs) => bs.map((b, i) => { b.dataset.chip = i; return i }))
    for (const i of chips) {
      const c = await contrast(`#help-flow .badge[data-chip="${i}"]`)
      if (c < 4.5) fail(`${where}: chip ${i} contrast ${c.toFixed(2)}`)
    }
    for (const sel of ['#flow-node-verifying p', '#flow-node-writing a', '#flow-verifying [data-person] strong']) {
      const c = await contrast(sel)
      if (c < 4.5) fail(`${where}: ${sel} contrast ${c.toFixed(2)}`)
    }
    ok(`${where}: text on the tints and all ${chips.length} chips reads (4.5:1 or better)`)

    await noSideScroll(where)
    ok(`${where}: nothing scrolls sideways`)
    await page.$eval('#help', (e) => e.scrollTo(0, 0))
    await page.$eval('#flow-diagram', (e) => e.scrollIntoView())
    await snap(`help-flow-${label}-${scheme}-diagram`)
    await page.$eval('#flow-verifying', (e) => e.scrollIntoView())
    await snap(`help-flow-${label}-${scheme}-verifying`)
  }
}

await browser.close()
console.log('help-flow: all good')
