// The browser half of tools/e2e/view-columns.sh (#3665).
//
//   node tools/e2e/view-columns.mjs <login-url> <base-url> <board-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const shots = process.env.SHOTS

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()

// The keys of the headings in `selector`, in the order drawn.
const headings = (selector) =>
  page.$$eval(`${selector} > [data-col]`, els => els.map(e => e.dataset.col))

const settle = () => page.waitForTimeout(400)

async function open(path) {
  await page.goto(`${base}/boards/${board}/${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

async function openDisplay() {
  await page.click('#display-menu [aria-label="Display options"]')
  await page.waitForSelector('#display-menu .dropdown-content', { state: 'visible' })
}

// Drags the grip of `key` in a Columns list onto the row of `onto`, ending in
// its upper half so it lands before it.
async function dragGrip(view, key, onto) {
  const grip = page.locator(`#col-grip-${view}-${key}`)
  const target = page.locator(`#col-${view}-${onto}`)
  const g = await grip.boundingBox()
  const t = await target.boundingBox()
  await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2)
  await page.mouse.down()
  // Sortable follows the pointer in steps (its fallback drag), so go slowly.
  const endY = t.y + t.height * 0.3
  for (let i = 1; i <= 24; i++) {
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2 + (endY - g.y - g.height / 2) * (i / 24))
    await page.waitForTimeout(40)
  }
  await page.waitForTimeout(150)
  await page.mouse.up()
  await settle()
}

// Drags the edge of a heading by `dx` pixels; returns the heading's width before and after.
async function dragEdge(view, key, dx, heading) {
  const handle = page.locator(`#col-resize-${view}-${key}`)
  const before = (await page.locator(heading).boundingBox()).width
  const h = await handle.boundingBox()
  await page.mouse.move(h.x + h.width / 2, h.y + h.height / 2)
  await page.mouse.down()
  for (let i = 1; i <= 8; i++) await page.mouse.move(h.x + h.width / 2 + (dx * i) / 8, h.y + h.height / 2)
  await page.mouse.up()
  await settle()
  const after = (await page.locator(heading).boundingBox()).width
  return { before, after }
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // --- The table ---------------------------------------------------------
  await open('table?fields=title,column,priority,tags')
  await page.waitForSelector('#card-table')
  let order = await headings('#card-table thead tr')
  if (order.join() !== 'title,column,priority,tags') fail(`table starts as ${order}`)

  await openDisplay()
  await dragGrip('table', 'tags', 'column')
  order = await headings('#card-table thead tr')
  if (order.join() !== 'title,tags,column,priority') fail(`dragging Tags above List gave ${order}`)
  if (!page.url().includes('fields=title%2Ctags%2Ccolumn%2Cpriority')) fail(`URL after the move: ${page.url()}`)
  // The menu stays open and in the new order.
  const menu = await page.$$eval('#display-fields-comfortable-list > li', els => els.map(e => e.dataset.id))
  if (menu.slice(0, 4).join() !== 'title,tags,column,priority') fail(`menu after the move: ${menu}`)
  // The menu stays open, the grip keeps its focus, and ↓ moves it on a place.
  const focused = await page.evaluate(() => document.activeElement.id)
  if (focused !== 'col-grip-table-tags') fail(`after the drop focus is on "${focused}"`)
  if (!(await page.isVisible('#display-fields-comfortable-list'))) fail('the Display menu shut after the drop')
  console.log('ok: a column dragged in the Display menu moves in the table, menu still open')

  await page.keyboard.press('ArrowDown')
  await settle()
  order = await headings('#card-table thead tr')
  if (order.join() !== 'title,column,tags,priority') fail(`↓ on the Tags grip gave ${order}`)
  if (!(await page.isVisible('#display-fields-comfortable-list'))) fail('the Display menu shut after ↓')
  await page.keyboard.press('ArrowUp')
  await settle()
  order = await headings('#card-table thead tr')
  if (order.join() !== 'title,tags,column,priority') fail(`↑ on the Tags grip gave ${order}`)
  console.log('ok: ↑ and ↓ on a grip move its column, the menu open throughout')

  // The title moves and hides like the rest (#3748).
  await page.focus('#col-grip-table-title')
  await page.keyboard.press('ArrowDown')
  await settle()
  await page.keyboard.press('ArrowDown')
  await settle()
  order = await headings('#card-table thead tr')
  if (order.join() !== 'tags,column,title,priority') fail(`↓↓ on the Title grip gave ${order}`)
  const titleCell = await page.$eval('#card-table tbody tr[id^=row-] td:nth-child(3)', td => td.textContent)
  if (!/epic|Second card/.test(titleCell)) fail(`the third cell is not the title: ${titleCell}`)
  await page.uncheck('#col-table-title input[type=checkbox]')
  await settle()
  order = await headings('#card-table thead tr')
  if (order.join() !== 'tags,column,priority') fail(`unticking Title gave ${order}`)
  if (!(await page.isVisible('#display-fields-comfortable-list'))) fail('the Display menu shut after unticking')
  await page.check('#col-table-title input[type=checkbox]')
  await settle()
  await dragGrip('table', 'title', 'tags')
  order = await headings('#card-table thead tr')
  if (order.join() !== 'title,tags,column,priority') fail(`Title back first gave ${order}`)
  console.log('ok: the Title column is dragged, hidden and shown again like the others')

  await page.keyboard.press('Escape')
  await page.mouse.click(700, 800)

  const sortBefore = page.url()
  const pri = await dragEdge('table', 'priority', 90, '#card-table th[data-col=priority]')
  if (Math.abs(pri.after - (pri.before + 90)) > 6) fail(`priority went ${pri.before} -> ${pri.after}, not +90`)
  if (!/widths=priority%3A\d+/.test(page.url())) fail(`URL after the resize: ${page.url()}`)
  if (page.url().includes('sort=')) fail(`dragging the edge sorted the table: ${sortBefore} -> ${page.url()}`)
  console.log(`ok: dragging Priority's edge widened it ${Math.round(pri.before)} -> ${Math.round(pri.after)}`)

  const title = await dragEdge('table', 'title', -10000, '#card-table th[data-col=title]')
  if (title.after > 60) fail(`the title column did not narrow to the minimum: ${title.after}`)
  const cell = await page.$eval('#card-table tbody tr[id^=row-] td:first-child', td => td.getBoundingClientRect().width)
  if (cell > 60) fail(`the title cells kept their width: ${cell}`)
  console.log(`ok: the title column narrows to ${Math.round(title.after)}px, cells and all`)

  if (shots) await page.screenshot({ path: `${shots}/table.png` })
  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const kept = (await page.locator('#card-table th[data-col=priority]').boundingBox()).width
  if (Math.abs(kept - pri.after) > 6) fail(`after a reload priority is ${kept}, was ${pri.after}`)

  // Both back to their own: the narrowed title gave the auto columns its room.
  await page.dblclick('#col-resize-table-title')
  await settle()
  await page.dblclick('#col-resize-table-priority')
  await settle()
  if (page.url().includes('widths=')) fail(`a double-click left a width: ${page.url()}`)
  const reset = (await page.locator('#card-table th[data-col=priority]').boundingBox()).width
  if (Math.abs(reset - pri.before) > 6) fail(`after a reset priority is ${reset}, was ${pri.before}`)
  console.log('ok: the width survives a reload, and a double-click puts it back')

  // --- The outline -------------------------------------------------------
  await open('outline')
  await page.waitForSelector('#outline')
  order = await headings('#outline .ol-head')
  if (order.join() !== 'card,list,progress,schedule,health,actions') fail(`outline starts as ${order}`)

  await openDisplay()
  await page.uncheck('#col-outline-progress input[type=checkbox]')
  await settle()
  order = await headings('#outline .ol-head')
  if (order.includes('progress')) fail(`Progress is still drawn: ${order}`)
  await dragGrip('outline', 'health', 'list')
  order = await headings('#outline .ol-head')
  if (order.join() !== 'card,health,list,schedule,actions') fail(`outline after hide and move: ${order}`)
  const row = await page.$eval('#outline .ol-row:not(.ol-head)', r =>
    [...r.querySelectorAll(':scope > [data-col]')].map(e => e.dataset.col))
  if (row.join() !== order.join()) fail(`a row's cells are ${row}, the headings ${order}`)
  // Each heading sits over its cells.
  const lined = await page.evaluate(() => {
    const head = [...document.querySelectorAll('#outline .ol-head > [data-col]')]
    const cells = [...document.querySelectorAll('#outline .ol-row:not(.ol-head)')][0].querySelectorAll(':scope > [data-col]')
    return head.every((h, i) => Math.abs(h.getBoundingClientRect().left - cells[i].getBoundingClientRect().left) < 2)
  })
  if (!lined) fail('the outline headings and cells are out of line')
  console.log('ok: the outline hides and moves a column, cells under headings')

  await page.keyboard.press('Escape')
  await page.mouse.click(700, 850)
  const list = await dragEdge('outline', 'list', 70, '#outline .ol-head > [data-col=list]')
  if (Math.abs(list.after - (list.before + 70)) > 6) fail(`outline List went ${list.before} -> ${list.after}`)
  if (shots) await page.screenshot({ path: `${shots}/outline.png` })
  console.log('ok: dragging the outline List edge widens it')

  // --- Prioritise --------------------------------------------------------
  await open('prioritise')
  await page.waitForSelector('#prioritise-table')
  order = await headings('#prioritise-table thead tr')
  const formula = order[order.length - 1]
  await openDisplay()
  const fid = formula.replace(':', '-')
  await dragGrip('prioritise', fid, 'priority')
  order = await headings('#prioritise-table thead tr')
  if (order[0] !== formula || order[1] !== 'priority') fail(`dragging the formula first gave ${order}`)
  await page.uncheck('#col-prioritise-votes input[type=checkbox]')
  await settle()
  order = await headings('#prioritise-table thead tr')
  if (order.includes('votes')) fail(`Votes still drawn: ${order}`)
  if (await page.locator('#prioritise-table tbody [phx-click=prio_vote]').count()) fail('vote buttons still drawn')
  await page.keyboard.press('Escape')
  await page.mouse.click(700, 850)
  const card = await dragEdge('prioritise', 'card', 120, '#prioritise-table thead th:nth-child(2)')
  if (Math.abs(card.after - (card.before + 120)) > 6) fail(`Prioritise Card went ${card.before} -> ${card.after}`)
  if (shots) await page.screenshot({ path: `${shots}/prioritise.png` })
  console.log('ok: Prioritise moves, hides and resizes its columns')
} finally {
  await browser.close()
}
