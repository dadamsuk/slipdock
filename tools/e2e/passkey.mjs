// The browser half of tools/e2e/passkey.sh (#828).
//
//   node tools/e2e/passkey.mjs <login-url> <base-url>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [rawLogin, base] = process.argv.slice(2)
// The link is made for 127.0.0.1; the cookie, and the passkey, are localhost's.
const loginUrl = rawLogin.replace(/^https?:\/\/[^/]+/, base)
const fail = (why) => { console.error('FAIL: ' + why); process.exit(1) }
const ok = (what) => console.log('ok: ' + what)

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 1200, height: 900 } })
const page = await context.newPage()

// A platform authenticator that holds discoverable credentials and verifies
// its user without asking: the fingerprint, always accepted.
const cdp = await context.newCDPSession(page)
await cdp.send('WebAuthn.enable')
const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
  options: {
    protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
    hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true,
  },
})

const connected = () => page.waitForSelector('.phx-connected', { timeout: 15000 })
const flash = async (text) => {
  try { await page.getByText(text).first().waitFor({ timeout: 8000 }) } catch { fail(`no "${text}" on ${page.url()}:\n${(await page.innerText('body')).slice(0, 800)}`) }
}

try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  // Adding one.
  await page.goto(`${base}/account`, { waitUntil: 'networkidle' })
  await connected()
  await page.waitForSelector('#passkey-add-form', { timeout: 8000 }).catch(() => fail('no add form: the hook did not say the browser can'))
  await page.fill('#passkey-add-form input[name=name]', 'E2E key')
  await page.click('#passkey-add-form button[type=submit]')
  await flash('Passkey “E2E key” added')
  await page.locator('#passkeys li', { hasText: 'E2E key' }).waitFor()
  const { credentials } = await cdp.send('WebAuthn.getCredentials', { authenticatorId })
  if (credentials.length !== 1 || !credentials[0].isResidentCredential) fail(`authenticator holds ${JSON.stringify(credentials)}`)
  ok('added a discoverable passkey from the account page')

  // The same authenticator again is excluded, and says so.
  await page.click('#passkey-add-form button[type=submit]')
  await flash('already on your account')
  if (await page.locator('#passkeys li').count() !== 1) fail('a second passkey was added on the same authenticator')
  ok('the same authenticator cannot be added twice')

  // Signing in with it, from nothing: no email typed.
  await context.clearCookies()
  await page.goto(`${base}/login`, { waitUntil: 'networkidle' })
  await connected()
  await page.waitForSelector('#passkey-login-button', { timeout: 8000 }).catch(() => fail('no passkey button on the login page'))
  await Promise.all([page.waitForURL(u => !u.pathname.startsWith('/login'), { timeout: 15000 }), page.click('#passkey-login-button')])
  await flash('Welcome back')
  ok(`signed in with the passkey, landed on ${new URL(page.url()).pathname}`)

  await page.goto(`${base}/account`, { waitUntil: 'networkidle' })
  await connected()
  await page.locator('#passkeys li', { hasText: 'used' }).filter({ hasNotText: 'not used yet' }).waitFor({ timeout: 8000 })
    .catch(() => fail('the passkey does not say it was used'))
  ok('the account page says when it was last used')

  // Removing it, through the app's own confirm box.
  await page.locator('#passkeys li button', { hasText: 'Remove' }).click()
  await page.locator('#confirm-dialog button', { hasText: 'Remove' }).click()
  await flash('Passkey removed')
  await page.locator('#passkeys-empty').waitFor()
  ok('removed it')

  // The authenticator still holds it, but the server no longer takes it.
  await context.clearCookies()
  await page.goto(`${base}/login`, { waitUntil: 'networkidle' })
  await connected()
  await page.waitForSelector('#passkey-login-button')
  await Promise.all([page.waitForURL(u => u.pathname === '/login', { timeout: 15000 }), page.click('#passkey-login-button')])
  await flash("can't sign in here")
  ok('a removed passkey is refused')
} finally {
  await browser.close()
}
