// The browser half of tools/e2e/home-vaults.sh: the vault's card
// among the boards, a drag that puts it first, and New vault.
//
//   node tools/e2e/home-vaults.mjs <login-url> <base-url> <kb-id> <hunt-id>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, kb, hunt] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const shots = process.env.SHOTS

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } })

const order = () => page.$$eval('#boards > [data-id]', (els) => els.map((e) => e.dataset.id))

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  await page.goto(`${base}/`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')

  // One grid: the boards in the order they were made, the vault after them.
  const card = page.locator('[id^="vault-"][data-id^="vault-"]').first()
  await card.waitFor()
  const vaultKey = await card.getAttribute('data-id')
  const before = await order()
  if (JSON.stringify(before) !== JSON.stringify([kb, hunt, vaultKey])) fail('order: ' + before)
  if (!(await card.innerText()).includes('Keystone · Journal Desk')) fail('card: ' + await card.innerText())
  if (await page.locator('body', { hasText: 'get things done' }).count()) fail('the slogan is still there')
  if (shots) await page.screenshot({ path: `${shots}/home-before.png`, fullPage: true })

  // The two New buttons look alike.
  const cls = (sel) => page.locator(sel).first().getAttribute('class')
  if ((await cls('button[phx-click=start_create]')) !== (await cls('#new-vault'))) fail('the buttons differ')

  // Drag the vault by its handle onto the first board.
  await card.hover()
  const handle = card.locator('.board-handle')
  const from = await handle.boundingBox()
  const to = await page.locator(`#board-${kb}`).boundingBox()
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2)
  await page.mouse.down()
  for (let i = 1; i <= 20; i++) {
    await page.mouse.move(
      from.x + (to.x + 20 - from.x) * (i / 20),
      from.y + (to.y + 20 - from.y) * (i / 20),
    )
  }
  await page.mouse.up()
  await page.waitForFunction((key) => document.querySelector('#boards > [data-id]').dataset.id === key, vaultKey)

  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
  const after = await order()
  if (after[0] !== vaultKey) fail('after reload: ' + after)

  // New vault, from its button.
  await page.click('#new-vault')
  await page.fill('#new-vault-name', 'Fresh')
  await page.click('#new-vault-form button[type=submit]')
  await page.locator('[id^="vault-tile-"]', { hasText: 'Fresh' }).waitFor()
  if (shots) await page.screenshot({ path: `${shots}/home-after.png`, fullPage: true })

  console.log('ok: the vault is a card among the boards, moves like one, and New vault works')
} finally {
  await browser.close()
}
