// The browser half of tools/e2e/trust-contract.sh (#2581): the trust
// contract rendered from its one text on Help › Agents › Runners and on a
// machine's page, at 1280 and 390 wide.
//
//   node tools/e2e/trust-contract.mjs <login-url> <base-url> <machine-id> <contract.md>
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(require.resolve('playwright-core', { paths: (process.env.NODE_PATH||'').split(':') }))
const [loginUrl, base, machineId, source] = process.argv.slice(2)
const shots = process.env.SHOTS
const fail = (w) => { throw new Error(w) }
const ok = (w) => console.log(`ok: ${w}`)

const text = readFileSync(source, 'utf8')
const headings = [...text.matchAll(/^#### (.+)$/gm)].map((m) => m[1])
const bullets = [...text.matchAll(/^- /gm)].length

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
try {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])

  const check = async (path, section, name) => {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 900 })
      await page.goto(`${base}${path}`, { waitUntil: 'load' })
      await page.waitForSelector('.phx-connected')
      const el = page.locator(section)
      await el.scrollIntoViewIfNeeded()
      const seen = await el.evaluate((s) => ({
        h4: [...s.querySelectorAll('h4')].map((h) => h.textContent.trim()),
        h4Bold: [...s.querySelectorAll('h4')].every((h) => Number(getComputedStyle(h).fontWeight) >= 600),
        li: s.querySelectorAll('li').length,
        disc: [...s.querySelectorAll('ul')].every((u) => getComputedStyle(u).listStyleType === 'disc'),
        code: [...s.querySelectorAll('li code')].map((c) => c.textContent),
        br: s.querySelectorAll('[data-role=trust-contract] br').length,
        wide: s.scrollWidth > s.clientWidth + 1 || document.documentElement.scrollWidth > window.innerWidth + 1,
      }))
      JSON.stringify(seen.h4) === JSON.stringify(headings) || fail(`${name} ${width}: headings ${seen.h4}`)
      seen.h4Bold || fail(`${name} ${width}: headings not set as headings`)
      seen.li === bullets || fail(`${name} ${width}: ${seen.li} bullets, the text has ${bullets}`)
      seen.disc || fail(`${name} ${width}: a list without bullets`)
      for (const e of ['me', 'user', 'confined', 'container']) seen.code.includes(e) || fail(`${name} ${width}: no ${e}`)
      seen.br === 0 || fail(`${name} ${width}: the terminal's line wraps shown as breaks`)
      !seen.wide || fail(`${name} ${width}: wider than the screen`)
      if (shots) await el.screenshot({ path: `${shots}/trust-contract-${name}-${width}.png` })
      ok(`${name} at ${width}: ${headings.length} headings, ${bullets} bullets, nothing too wide`)
    }
  }

  await check('/help/agents/runners', '#help-trust-contract', 'help')
  await check(`/machines/${machineId}`, '#machine-trust-contract', 'machine')
  console.log('ok')
} finally {
  await browser.close()
}
