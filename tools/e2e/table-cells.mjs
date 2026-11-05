// The browser half of tools/e2e/table-cells.sh (#1731).
//
//   - at rest, no select in the table body draws its caret (its computed
//     background-image, where daisyUI paints it) and no empty date shows
//     "Add date" or a native dd/mm/yyyy;
//   - hovering a row brings the carets back, and so does focusing a cell;
//   - each row has one due value, coloured by its state;
//   - rows are the same height, a long tag list included, which shows "+N"
//     with every tag in its tooltip;
//   - the Assignee column is shown by default and the Display menu hides it;
//   - Tab walks title, list, priority, due and done in each row;
//   - editing list, priority and due saves (still there after a reload).
//
//   node tools/e2e/table-cells.mjs <login-url> <base-url> <board-id> <many> <soon> <bare> <todo-list>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, many, soon, bare, todo] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const shot = async (page, name) => { if (shots) await page.screenshot({ path: `${shots}/table-cells-${name}.png` }) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 700 } })).newPage()

const open = async (query = '') => {
  await page.goto(`${base}/boards/${board}/table${query}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  await page.waitForSelector('#card-table')
  await page.addStyleTag({ content: '*, *::before, *::after { transition: none !important; animation: none !important; }' })
  await page.mouse.move(5, 690)
}

// What the table body shows at rest: selects whose caret is painted, and
// date texts or native date inputs that can be seen (opacity along the way).
const rest = () => page.evaluate(() => {
  const seen = (el) => {
    for (let e = el; e; e = e.parentElement) {
      const s = getComputedStyle(e)
      if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false
    }
    return el.getClientRects().length > 0
  }
  const body = [...document.querySelectorAll('#card-table tbody')]
  const selects = body.flatMap((b) => [...b.querySelectorAll('select')])
  return {
    selects: selects.length,
    carets: selects.filter((s) => getComputedStyle(s).backgroundImage !== 'none').map((s) => s.closest('form').id),
    placeholders: body.flatMap((b) => [...b.querySelectorAll('[data-role=date-text]')])
      .filter((t) => t.textContent.trim() === 'Add date' && seen(t)).length,
    natives: body.flatMap((b) => [...b.querySelectorAll('input[type=date]')]).filter(seen).length,
  }
})

const caret = (formId) => page.evaluate((id) =>
  getComputedStyle(document.querySelector(`#${id} select`)).backgroundImage !== 'none', formId)

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
  await open()
  await shot(page, 'rest')

  // 1. Nothing at rest.
  const r = await rest()
  console.log('at rest', JSON.stringify(r))
  if (r.selects < 6) fail(`expected list and priority selects on every row, found ${r.selects}`)
  if (r.carets.length) fail(`selects draw their caret at rest: ${r.carets.join(', ')}`)
  if (r.placeholders) fail(`${r.placeholders} empty due dates say "Add date" at rest`)
  if (r.natives) fail(`${r.natives} native date inputs are visible at rest`)

  // 2. Hover brings the controls back.
  await page.hover(`tr[id$="-${many}"] td:nth-child(2)`)
  if (!(await caret(`col-${many}`))) fail('hovering a row does not show its list caret')
  if (!(await caret(`prio-${many}`))) fail('hovering a row does not show its priority caret')
  if (await caret(`col-${soon}`)) fail('hovering one row shows the carets of another')
  await page.hover(`tr[id$="-${bare}"] td:nth-child(2)`)
  const hoverText = await page.evaluate((id) => {
    const t = document.querySelector(`#due-${id} [data-role=date-text]`)
    return { text: t.textContent.trim(), opacity: getComputedStyle(t).opacity }
  }, bare)
  if (hoverText.opacity === '0') fail('hovering an empty due date still hides "Add date"')
  await shot(page, 'hover')
  await page.mouse.move(5, 690)

  // 3. One due value per row, coloured by its state; equal heights; tags on one line.
  const rows = await page.evaluate(([many, soon, bare]) => {
    const head = [...document.querySelectorAll('#card-table thead th')].map((th) => th.innerText.trim().toLowerCase())
    const at = (name) => head.indexOf(name)
    return {
      head,
      rows: [many, soon, bare].map((id) => {
        const tr = document.querySelector(`tr[id$="-${id}"]`)
        const due = tr.children[at('due')]
        const tags = tr.children[at('tags')]
        const text = due.querySelector('[data-role=date-text]')
        return {
          id,
          // Inside its rules: the last row has no bottom one.
          height: tr.firstElementChild.clientHeight,
          dueFields: due.querySelectorAll('.date-field').length,
          dueChips: due.querySelectorAll('.hero-clock').length,
          dueState: due.querySelector('form').dataset.due || '',
          dueColor: getComputedStyle(text).color,
          tagLines: tags.firstElementChild ? Math.round(tags.firstElementChild.getBoundingClientRect().height) : 0,
          tagTitle: tags.querySelector('[title]')?.getAttribute('title') || '',
          more: tags.querySelector('[data-role=more-tags]')?.textContent.trim() || '',
        }
      }),
    }
  }, [many, soon, bare])
  console.log(JSON.stringify(rows))
  if (!rows.head.includes('assignee')) fail(`no Assignee column by default: ${rows.head}`)
  for (const row of rows.rows) {
    if (row.dueFields !== 1) fail(`row ${row.id} has ${row.dueFields} due fields`)
    if (row.dueChips) fail(`row ${row.id} repeats its due date in a chip`)
  }
  const [m, s, b] = rows.rows
  if (m.dueState !== 'overdue') fail(`the overdue card's date is "${m.dueState}", not overdue`)
  if (s.dueState !== 'soon') fail(`the card due tomorrow is "${s.dueState}", not soon`)
  if (m.dueColor === s.dueColor) fail('overdue and soon dates share a colour')
  const heights = rows.rows.map((x) => x.height)
  if (Math.max(...heights) - Math.min(...heights) > 0.5) fail(`row heights differ: ${heights}`)
  if (m.more !== '+4') fail(`six tags show "${m.more}", not two and "+4"`)
  for (const name of ['frontend', 'needs-design-review', 'documentation'])
    if (!m.tagTitle.includes(name)) fail(`the tags tooltip lacks ${name}: "${m.tagTitle}"`)
  if (s.more) fail(`one tag shows a "${s.more}"`)

  // 4. Tab walks the editable cells of a row, and a focused select shows its caret.
  await page.focus(`tr[id$="-${many}"] [phx-click=open_card]`)
  const walk = []
  for (let i = 0; i < 6; i++) {
    await page.keyboard.press('Tab')
    walk.push(await page.evaluate(() => {
      const el = document.activeElement
      const form = el.closest('form')
      return `${form ? form.id.replace(/-\d+$/, '') : el.tagName.toLowerCase()}:${el.tagName.toLowerCase()}`
    }))
    if (i === 0 && !(await caret(`col-${many}`))) fail('a focused list select hides its caret')
  }
  // The due cell holds two stops when it has a date: the date and its ×.
  const steps = walk.filter((w, i) => w !== walk[i - 1])
  console.log('tab order', walk.join(' > '))
  const want = ['col:select', 'prio:select', 'due:button', 'input:input']
  if (steps.slice(0, 4).join() !== want.join()) fail(`Tab goes ${walk.join(' > ')}, not ${want.join(' > ')}`)
  if (!steps[4]?.startsWith('span')) fail(`Tab after the done box goes to ${steps[4]}, not the next title`)
  await page.focus(`#col-${many} select`)
  await shot(page, 'focus')

  // 5. Edits save.
  const settle = () => page.waitForFunction(() => !document.querySelector('.phx-change-loading'))
  await page.selectOption(`#prio-${soon} select`, 'critical'); await settle()
  await page.selectOption(`#col-${soon} select`, { index: 0 }); await settle()
  await page.locator(`#due-${bare} input[type=date]`).fill('2031-02-03'); await settle()
  await page.waitForTimeout(500)
  await open()
  const saved = await page.evaluate(([soon, bare, todo]) => ({
    prio: document.querySelector(`#prio-${soon} select`).value,
    col: document.querySelector(`#col-${soon} select`).value,
    due: document.querySelector(`#due-${bare} input[type=date]`).value,
    todo,
  }), [soon, bare, todo])
  console.log('after reload', JSON.stringify(saved))
  if (saved.prio !== 'critical') fail(`priority did not save: ${saved.prio}`)
  if (saved.col === saved.todo) fail('the list did not save')
  if (saved.due !== '2031-02-03') fail(`the due date did not save: ${saved.due}`)

  // 6. The Display menu hides the Assignee column.
  await page.click('#display-menu [role=button]')
  await page.locator('#display-menu input[name="fields[]"][value=assignee]').uncheck()
  await page.waitForFunction(() =>
    ![...document.querySelectorAll('#card-table thead th')].some((th) => /assignee/i.test(th.innerText)))
  if (!page.url().includes('fields=')) fail('hiding Assignee is not in the URL')
  await open()
  await shot(page, 'rest-after-edits')

  console.log('ok: cells are text at rest, controls on hover and focus, one due value, even rows, Assignee by default')
} finally {
  await browser.close()
}
