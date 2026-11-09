// The browser half of tools/e2e/machines-page.sh (#2572): the owner adds a
// runner whose timeout is over the machine's ceiling, sees the field marked
// with the limit, saves it, and, once the machine refuses it, sees the
// refusal with its reason and the limit without reloading.
//
//   node tools/e2e/machines-page.mjs <login-url> <base-url> <machine-id> <machine-key>
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, machineId, machineKey] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (w) => { throw new Error(w) }
const ok = (w) => console.log(`ok: ${w}`)

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // From Account › Machines to the machine's page.
  await page.goto(`${base}/account/machines`, { waitUntil: 'load' })
  await page.waitForSelector('.phx-connected')
  await page.click(`#machine-${machineId} a[href="/machines/${machineId}"]`)
  await page.waitForSelector('#machine-ceiling')
  ;(await page.locator('#machine-ceiling').innerText()).includes('60 minutes') || fail('ceiling not shown')
  ok('the machine opens from Account › Machines, with its ceiling')

  // A runner with a timeout over the ceiling: marked with the limit as typed.
  await page.click('#machine-add-runner')
  await page.waitForSelector('#machine-runner-form')
  await page.fill('#machine-runner-form input[name="runner[directory]"]', '/srv/src/app')
  await page.fill('#machine-runner-form input[name="runner[timeout_minutes]"]', '240')
  await page.locator('#machine-runner-form input[name="runner[timeout_minutes]"]').blur()
  await page.waitForSelector('#machine-runner-form p:has-text("timeout 240 minutes is over 60")', { timeout: 5000 })
  await page.waitForSelector('#machine-runner-form-outside')
  ok('the timeout is marked with the limit as it is typed')
  if (shots) await page.screenshot({ path: `${shots}/machines-page-form.png` })

  await page.click('#machine-runner-form button[type=submit]')
  await page.waitForSelector('#machine-notice:has-text("saved")')
  await page.waitForSelector('[id^=machine-runner-]:has-text("Outside the ceiling")')
  ok('saved, and marked outside the ceiling until the machine answers')

  // The machine refuses it, as the daemon would: with its key, over the API.
  const auth = { Authorization: `Bearer ${machineKey}`, 'Content-Type': 'application/json' }
  const config = await (await fetch(`${base}/api/machine/config`, { headers: auth })).json()
  const runner = config.runners[0] || fail('no runner in the machine config')
  const res = await fetch(`${base}/api/machine/runners/${runner.id}/report`, {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({
      version: runner.config_version,
      outcome: 'rejected',
      reason: 'timeout_minutes 240 is over this machine\'s ceiling of 60',
    }),
  })
  res.ok || fail(`report refused: ${res.status}`)

  const rejection = page.locator(`#machine-runner-${runner.id}-rejection`)
  await rejection.waitFor({ timeout: 5000 })
  const text = await rejection.innerText()
  text.includes(`The machine refused v${runner.config_version}`) || fail(`no title: ${text}`)
  text.includes("ceiling of 60") || fail(`no reason: ${text}`)
  text.includes('timeout 240 minutes is over 60') || fail(`no limit: ${text}`)
  ;(await page.locator(`#machine-runner-${runner.id} [data-role=runner-state]`).innerText()).includes('rejected') ||
    fail('state is not rejected')
  ;(await page.locator('#machine-log').innerText()).includes('rejected') || fail('log has no rejection')
  ok('the refusal shows live, with its reason and the limit')
  if (shots) await page.screenshot({ path: `${shots}/machines-page-rejected.png`, fullPage: true })

  // Removing it goes through the app's confirm dialog.
  await page.click(`#machine-runner-${runner.id} button:has-text("Remove")`)
  await page.click('[data-confirm-ok]')
  await page.waitForSelector(`#machine-runner-${runner.id}`, { state: 'detached', timeout: 5000 })
  ok('removed after the confirm dialog')
  console.log('ok')
} finally {
  await browser.close()
}
