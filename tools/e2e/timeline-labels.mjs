// The browser half of tools/e2e/timeline-labels.sh (#1732), on a timeline
// seeded with a wide bar, short bars, a due-only bar, a bar at the window's
// right edge, one clipped there, and dependencies between them:
//   - every bar's title is shown whole (none cut with an ellipsis), beside
//     the bar when the bar is too short, on the left when the right has no
//     room;
//   - no dependency line is painted over a label: each point of each line
//     that falls inside a label's box is hit-tested, and what is on top there
//     must be the label (or its bar), not the line;
//   - the label column's handle drags it wider, a reload keeps the width, and
//     a double-click puts it back;
//   - the Unscheduled tray starts right under the last row.
//
//   node tools/e2e/timeline-labels.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const failures = []
const fail = (w) => failures.push(w)
const shot = async (name) => process.env.SHOTS && page.screenshot({ path: `${process.env.SHOTS}/timeline-labels-${name}.png` })
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

const open = async () => {
  await page.goto(`${base}/boards/${board}/timeline`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#timeline .tl-bar')
  await page.addStyleTag({ content: '*, *::before { transition: none !important; animation: none !important; }' })
  // Show the right-hand end of the window, where the edge bars are.
  await page.evaluate(() => { const s = document.getElementById('timeline-scroll'); s.scrollLeft = s.scrollWidth })
  await page.waitForTimeout(150)
}

await open()
await shot('window')

// 1. Labels: whole, and on the side with room.
const labels = await page.evaluate(() => [...document.querySelectorAll('#timeline .tl-bar')].map((bar) => {
  const label = bar.querySelector('.tl-bar-label')
  const b = bar.getBoundingClientRect(), l = label.getBoundingClientRect()
  return {
    title: label.textContent.trim(), cut: label.scrollWidth > label.clientWidth + 1,
    side: l.left >= b.right - 1 ? 'right' : l.right <= b.left + 1 ? 'left' : 'inside',
  }
}))
const want = {
  'Onboarding flow redesign': 'inside',
  'Write the release notes': 'right',
  'Record the demo video': 'right',
  'Due-only launch checklist': 'right',
  'Finalise pricing page copy': 'left',
  'Runs past the window edge': 'left',
}
for (const [title, side] of Object.entries(want)) {
  const got = labels.find((l) => l.title === title)
  if (!got) { fail(`no bar for "${title}"`); continue }
  if (got.cut) fail(`"${title}": label cut short`)
  if (got.side !== side) fail(`"${title}": label ${got.side} of the bar, wanted ${side}`)
}

// 2. Lines under labels: hit-test every point of every line inside a label.
const overlaps = await page.evaluate(() => {
  const style = document.createElement('style')
  style.textContent = '.tl-links, .tl-links *, .tl-bar-label { pointer-events: auto !important; }'
  document.head.appendChild(style)
  const out = { paths: 0, inside: 0, visible: [] }
  const labels = [...document.querySelectorAll('#timeline .tl-bar-label')]
  for (const path of document.querySelectorAll('#tl-links path')) {
    out.paths++
    const m = path.getScreenCTM(), len = path.getTotalLength()
    for (let at = 0; at <= len; at += 1.5) {
      const p = path.getPointAtLength(at)
      const x = m.a * p.x + m.c * p.y + m.e, y = m.b * p.x + m.d * p.y + m.f
      for (const label of labels) {
        const r = label.getBoundingClientRect()
        if (x <= r.left + 1 || x >= r.right - 1 || y <= r.top + 1 || y >= r.bottom - 1) continue
        out.inside++
        const top = document.elementFromPoint(x, y)
        if (top && top.closest('#tl-links')) out.visible.push(`${label.textContent.trim()} @${Math.round(x)},${Math.round(y)}`)
      }
    }
  }
  style.remove()
  return out
})
if (overlaps.paths < 3) fail(`only ${overlaps.paths} dependency lines drawn, wanted 3`)
if (overlaps.visible.length) fail(`dependency lines drawn over labels: ${[...new Set(overlaps.visible.map((v) => v.split(' @')[0]))].join(', ')} (${overlaps.visible.length} points)`)

// 4. The tray follows the rows.
const tray = await page.evaluate(() => {
  const rows = [...document.querySelectorAll('#timeline .tl-card-row')]
  const last = rows[rows.length - 1].getBoundingClientRect()
  const t = document.getElementById('dateless-cards').parentElement.getBoundingClientRect()
  return { gap: t.top - last.bottom, bottom: t.bottom, viewport: innerHeight }
})
if (tray.gap > 24) fail(`a ${Math.round(tray.gap)}px gap between the last row and the Unscheduled tray`)

// 3. The label column: drag wider, reload, double-click back.
const col = () => page.evaluate(() => document.querySelector('#timeline .tl-card-row > :first-child').getBoundingClientRect().width)
const before = await col()
const handle = page.locator('#timeline .tl-resize')
if (!(await handle.count())) fail('no handle on the label column')
else {
  const h = await handle.boundingBox()
  await page.mouse.move(h.x + h.width / 2, h.y + h.height / 2)
  await page.mouse.down()
  await page.mouse.move(h.x + h.width / 2 + 60, h.y + h.height / 2, { steps: 4 })
  await page.mouse.move(h.x + h.width / 2 + 120, h.y + h.height / 2, { steps: 4 })
  await page.mouse.up()
  const wider = await col()
  if (Math.abs(wider - before - 120) > 2) fail(`label column went ${before}px → ${wider}px on a 120px drag`)
  const long = await page.evaluate(() => {
    const s = [...document.querySelectorAll('#timeline .tl-card-row [role=link]')].find((e) => e.textContent.includes('Migrate billing'))
    return s.scrollWidth > s.clientWidth + 1
  })
  if (long) fail('the longest title is still cut in the widened column')
  await open()
  await shot('widened')
  const kept = await col()
  if (Math.abs(kept - wider) > 1) fail(`after a reload the column is ${kept}px, not ${wider}px`)
  await page.locator('#timeline .tl-resize').dblclick()
  const reset = await col()
  if (Math.abs(reset - before) > 1) fail(`a double-click left the column at ${reset}px, not ${before}px`)
}

console.log(JSON.stringify({ labels, overlaps: { ...overlaps, visible: overlaps.visible.length }, tray }, null, 1))
await browser.close()
if (failures.length) { console.error('FAIL\n- ' + failures.join('\n- ')); process.exit(1) }
console.log('timeline-labels: ok')
