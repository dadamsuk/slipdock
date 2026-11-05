// The browser half of tools/e2e/board-settings.sh (#1741).
//
//   node tools/e2e/board-settings.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH || '').split(':') }))
const [loginUrl, base, board] = process.argv.slice(2)
const shots = process.env.SHOTS
const before = process.env.BEFORE === '1'
const fail = (w) => { throw new Error(w) }
const near = (a, b, by = 1.5) => Math.abs(a - b) <= by

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } })
await page.goto(loginUrl, { waitUntil: 'networkidle' })
const confirm = page.locator('form[method=post] button[type=submit]').first()
if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.waitForTimeout(400)
}
const box = (sel) => page.locator(sel).first().boundingBox()
const shot = async (sel, name) => {
  if (shots) await page.locator(sel).first().screenshot({ path: `${shots}/${before ? 'before' : 'after'}-${name}.png` })
}

// --- Board settings ---------------------------------------------------------
await open(`/boards/${board}/settings`)
await shot('#settings-modal .kanban-modal-in', 'board-settings')

if (!before) {
  const modal = await box('#settings-modal .kanban-modal-in')
  if (modal.width > 900) fail(`the settings modal is ${modal.width}px wide, not sized to its form`)

  const column = await box('#settings-panel-general')
  if (column.width > 641) fail(`the form column is ${column.width}px, over 40rem`)

  const sizes = { '#board_shortcut': 80, '#board_code': 160, '#board_vote_budget': 100, '#board_vote_max': 100 }
  for (const [sel, most] of Object.entries(sizes)) {
    const b = await box(sel)
    if (b.width > most) fail(`${sel} is ${b.width}px wide, more than ${most}`)
    if (!near(b.height, 28)) fail(`${sel} is ${b.height}px tall, not the field's 28`)
  }

  // Pairs share a row.
  for (const [a, b] of [['#board_code', '#board_shortcut'], ['#board-hotkey', '#board-default-view'], ['#board_vote_budget', '#board_vote_max']]) {
    const [ba, bb] = [await box(a), await box(b)]
    if (!near(ba.y, bb.y)) fail(`${a} (y ${ba.y}) and ${b} (y ${bb.y}) are not side by side`)
    if (bb.x <= ba.x + ba.width) fail(`${b} overlaps ${a}`)
  }

  // Every label sits over its box, at its left edge, the same gap above.
  const labels = await page.$$eval('#settings-panel-general :is(input.field, select.field, textarea.field)', (els) =>
    els.map((el) => {
      const words = document.querySelector(`label[for="${el.id}"] .field-label`)
      if (!words) return null
      const [w, b] = [words.getBoundingClientRect(), el.getBoundingClientRect()]
      return { id: el.id, gap: b.top - w.bottom, dx: b.left - w.left }
    }).filter(Boolean))
  if (labels.length < 6) fail(`only ${labels.length} labelled fields found`)
  for (const l of labels) {
    if (!near(l.dx, 0)) fail(`${l.id}'s label is ${l.dx}px off its box's left edge`)
    if (l.gap < 0 || !near(l.gap, labels[0].gap)) fail(`${l.id}'s label is ${l.gap}px above its box, not ${labels[0].gap}`)
  }

  // Code is in the app's mono at the field's size, not a 34px serif.
  const font = await page.locator('#board_code').evaluate((el) => {
    const s = getComputedStyle(el)
    return { family: s.fontFamily, size: s.fontSize }
  })
  if (!/^"?JetBrains ?Mono/.test(font.family)) fail(`the code box is in ${font.family}`)
  if (font.size !== '13px') fail(`the code box is ${font.size}`)
  console.log(`ok: settings: modal ${modal.width}px, column ${column.width}px, short boxes sized, ${labels.length} labels stacked, code in ${font.family.split(',')[0]} ${font.size}`)
}

// --- Tags -------------------------------------------------------------------
await open(`/boards/${board}/tags`)
await shot('#tags-modal .kanban-modal-in', 'tags')

if (!before) {
  const idOf = async (name) => (await page.locator(`#tag-list input[data-name="${name}"]`).getAttribute('id')).replace('tag-name-', '')
  const urgent = await idOf('urgent')
  const later = await idOf('later')
  const nameOf = (id) => page.locator(`#tag-name-${id}`)
  const saved = (id, name) => page.waitForFunction(([i, n]) => document.getElementById(`tag-name-${i}`)?.dataset.name === n, [id, name], { timeout: 5000 })
    .catch(() => fail(`tag ${id} was not saved as ${name}`))

  // Rows are compact: one line each.
  const row = await box(`#tag-row-${urgent}`)
  if (row.height > 40) fail(`a tag row is ${row.height}px tall`)

  // The dot opens the palette; a swatch recolours and closes it.
  await page.click(`#tag-dot-${later}`)
  if (!(await page.locator(`#tag-colors-${later}`).evaluate((el) => el.matches(':popover-open')))) fail('the dot did not open the palette')
  const [dot, pal] = [await box(`#tag-dot-${later}`), await box(`#tag-colors-${later}`)]
  if (!near(pal.x, dot.x, 2) || pal.y < dot.y) fail(`the palette is not beside its dot (${pal.x},${pal.y} vs ${dot.x},${dot.y})`)
  await page.click(`#tag-colors-${later}-emerald`)
  await page.waitForSelector(`#tag-colors-${later}-emerald[aria-pressed="true"]`, { state: 'attached', timeout: 5000 })
  if (await page.locator(`#tag-colors-${later}`).evaluate((el) => el.matches(':popover-open'))) fail('the palette stayed open')
  if (!(await page.isVisible('#tags-modal'))) fail('picking a colour closed the panel')
  console.log('ok: tags: the dot opens the palette beside it, and a swatch recolours')

  // Enter saves.
  await nameOf(urgent).fill('on fire')
  await page.keyboard.press('Enter')
  await saved(urgent, 'on fire')

  // Leaving the box saves.
  await nameOf(urgent).fill('burning')
  await page.click('#tags-modal h2')
  await saved(urgent, 'burning')

  // Escape puts the name back, saves nothing and leaves the panel open.
  await nameOf(urgent).fill('never saved')
  await page.keyboard.press('Escape')
  await page.waitForTimeout(600)
  if ((await nameOf(urgent).inputValue()) !== 'burning') fail('Escape did not put the name back')
  if ((await nameOf(urgent).getAttribute('data-name')) !== 'burning') fail('Escape saved the name')
  if (!(await page.isVisible('#tags-modal'))) fail('Escape in the name box closed the panel')
  await page.reload({ waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  if ((await nameOf(urgent).inputValue()) !== 'burning') fail('Escape saved the name (after a reload)')
  console.log('ok: tags: Enter and leaving the box save the name, Escape puts it back')

  // An empty name and a duplicate are refused in the panel, and the box shows the saved name.
  for (const [typed, says] of [['', 'needs a name'], ['later', 'already a tag']]) {
    await nameOf(urgent).fill(typed)
    await page.keyboard.press('Enter')
    await page.waitForFunction((w) => document.getElementById('tags-error')?.textContent.includes(w), says, { timeout: 5000 })
      .catch(async () => fail(`"${typed}" said ${await page.locator('#tags-error').textContent().catch(() => 'nothing')}`))
    await page.waitForFunction((i) => document.getElementById(`tag-name-${i}`).value === 'burning', urgent, { timeout: 5000 })
      .catch(() => fail(`the box kept "${typed}" after it was refused`))
  }
  console.log('ok: tags: an empty name and a taken one are refused in the panel')

  // New tag, at the top.
  const list = await box('#tag-list')
  const add = await box('#tag-form')
  if (add.y > list.y) fail('New tag is not above the list')
  await page.fill('#new-tag-name', 'blocked')
  await page.keyboard.press('Enter')
  await page.waitForSelector('#tag-list input[data-name="blocked"]', { timeout: 5000 })
  console.log('ok: tags: New tag is one row at the top')

  // ⋯ then Delete, through the confirm.
  await page.click(`#tag-more-${later}`)
  await page.click(`#delete-tag-${later}`)
  await page.click('[data-confirm-ok]')
  await page.waitForSelector(`#tag-row-${later}`, { state: 'detached', timeout: 5000 })
  console.log('ok: tags: ⋯ Delete removes a tag after the confirm')
  await page.mouse.move(0, 0)
  await shot('#tags-modal .kanban-modal-in', 'tags-used')
}

// --- Automations, at two widths --------------------------------------------
for (const width of [1280, 1440]) {
  await page.setViewportSize({ width, height: 900 })
  await open(`/boards/${board}/automations`)
  await shot('#automations-modal .kanban-modal-in', `automations-${width}`)
  if (before) continue

  const groups = await page.$$eval('#rule-presets [data-role=preset-group]', (grids) => grids.map((grid) => {
    const label = grid.previousElementSibling.getBoundingClientRect()
    const g = grid.getBoundingClientRect()
    const buttons = [...grid.querySelectorAll('button')].map((b) => b.getBoundingClientRect())
    return {
      name: grid.previousElementSibling.textContent.trim(),
      labelRight: label.right,
      gridLeft: g.left,
      lefts: buttons.map((b) => Math.round(b.left)),
      tops: buttons.map((b) => Math.round(b.top)),
    }
  }))
  if (groups.length < 4) fail(`${width}: only ${groups.length} groups`)
  const columns = new Set()
  for (const g of groups) {
    for (const left of g.lefts) {
      if (left < g.labelRight) fail(`${width}: a ${g.name} button starts at ${left}, under the names (to ${g.labelRight})`)
      columns.add(left)
    }
    if (!near(Math.min(...g.lefts), g.gridLeft)) fail(`${width}: ${g.name}'s first button is not at its grid's left`)
  }
  // Aligned: every button starts on one of the grid's columns, shared by all groups.
  const perRow = Math.max(...groups.map((g) => new Set(g.lefts).size))
  if (columns.size !== perRow) fail(`${width}: buttons start at ${[...columns]}: not one set of columns`)

  // The switch is the brand toggle: primary when on.
  const sw = await page.$eval('#rule-switch-' + (await page.locator('[id^=rule-switch-]').first().getAttribute('id')).replace('rule-switch-', ''), (el) => {
    const s = getComputedStyle(el)
    const primary = getComputedStyle(document.documentElement).getPropertyValue('--color-primary')
    const probe = document.createElement('i')
    probe.style.color = primary
    document.body.append(probe)
    const p = getComputedStyle(probe).color
    probe.remove()
    return { role: el.getAttribute('role'), on: el.checked, bg: s.backgroundColor, primary: p }
  })
  if (sw.role !== 'switch' || !sw.on) fail(`${width}: the rule's switch is ${JSON.stringify(sw)}`)
  if (sw.bg !== sw.primary) fail(`${width}: the switch is ${sw.bg} when on, not the primary ${sw.primary}`)
  console.log(`ok: automations at ${width}: ${groups.length} groups in ${perRow} shared columns, none under the names; the switch is the primary`)
}
await browser.close()
