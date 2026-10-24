// The browser half of tools/e2e/inbound-email-to-card.sh (#1243).
//
//   node tools/e2e/inbound-email-to-card.mjs <login-url> <base-url> <board-id> <secret> [shots-dir]
import { createRequire } from 'node:module'
import { createHmac } from 'node:crypto'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [loginUrl, base, board, secret, shots] = process.argv.slice(2)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const sender = 'e2e@example.com'

// What the Worker posts: the raw message, the envelope, and an HMAC over
// "<timestamp>.<body>".
async function send(to, subject) {
  const id = `<${Date.now()}.${Math.random()}@example.com>`
  const raw = [
    'ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com;',
    ' dmarc=pass header.from=example.com',
    `From: E2E <${sender}>`, `To: ${to}`, `Subject: ${subject}`, `Message-ID: ${id}`,
    'MIME-Version: 1.0', 'Content-Type: multipart/mixed; boundary=b1', '',
    '--b1', 'Content-Type: text/plain; charset=utf-8', '', 'The report is attached.', '',
    '--b1', 'Content-Type: text/plain; name="report.txt"', 'Content-Disposition: attachment; filename="report.txt"', '',
    'all the numbers', '--b1--', '',
  ].join('\r\n')
  const ts = String(Math.floor(Date.now() / 1000))
  const signature = createHmac('sha256', secret).update(`${ts}.${raw}`).digest('hex')
  const res = await fetch(`${base}/api/inbound/email`, {
    method: 'POST',
    headers: {
      'content-type': 'message/rfc822', 'x-slipdock-timestamp': ts, 'x-slipdock-signature': signature,
      'x-envelope-to': to, 'x-envelope-from': sender,
    },
    body: raw,
  })
  return { status: res.status, body: await res.json() }
}

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage()
const shot = async (name) => { if (shots) await page.screenshot({ path: `${shots}/${name}.png` }) }

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

async function emailDialog() {
  await open(`/boards/${board}`)
  await page.click('#board-actions .dropdown [title="More"]')
  await page.click('#board-share-inbound')
  await page.locator('#board-inbound-card').waitFor()
  return (await page.locator('#board-inbound-card').innerText()).trim()
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  const address = await emailDialog()
  console.log(`ok: the board's card address, from the UI: ${address}`)

  const sent = await send(address, 'Fwd: Quarterly report')
  if (sent.status !== 202) fail(`mail to the card address answered ${sent.status} ${JSON.stringify(sent.body)}`)

  await open(`/boards/${board}`)
  const card = page.getByText('Quarterly report', { exact: true }).first()
  await card.waitFor({ timeout: 10000 }).catch(() => fail('no "Quarterly report" card on the board'))
  await card.click()
  await page.getByText('report.txt').first().waitFor({ timeout: 10000 }).catch(() => fail('the card has no report.txt'))
  await shot('card-from-email')
  console.log('ok: the email is a card on the board, "Quarterly report", with report.txt attached')

  await page.keyboard.press('Escape')
  await emailDialog()
  await page.click('#board-inbound-rotate')
  await page.click('[data-confirm-ok]')
  await page.locator('#board-inbound-rotated').waitFor()
  const fresh = (await page.locator('#board-inbound-card').innerText()).trim()

  const old = await send(address, 'To the old address')
  if (old.status !== 422 || !/no longer in use/.test(old.body.reject || '')) fail(`the old address answered ${old.status} ${JSON.stringify(old.body)}`)
  console.log(`ok: after New address, the old one bounces: "${old.body.reject}"`)

  const ok = await send(fresh, 'To the new address')
  if (ok.status !== 202) fail(`the new address answered ${ok.status} ${JSON.stringify(ok.body)}`)
  console.log('ok: the new address takes mail')
} finally {
  await browser.close()
}
