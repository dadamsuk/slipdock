// The browser half of tools/e2e/tool-install.sh (#966).
//
//   node tools/e2e/tool-install.mjs share  <login-url> <base-url>
//   node tools/e2e/tool-install.mjs browse <login-url> <base-url>
//   node tools/e2e/tool-install.mjs board  <login-url> <base-url> <board-code>
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [step, loginUrl, base, code] = process.argv.slice(2)
const fail = (why) => { throw new Error(why) }

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const context = await browser.newContext({ viewport: { width: 1400, height: 900 }, acceptDownloads: true })
const page = await context.newPage()

async function signIn() {
  await page.goto(loginUrl, { waitUntil: 'networkidle' })
  const confirm = page.locator('form[method=post] button[type=submit]').first()
  if (await confirm.count()) await Promise.all([page.waitForNavigation(), confirm.click()])
}

async function open(path) {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.phx-connected')
}

try {
  await signIn()

  if (step === 'share') {
    await open('/tools/job-scan')
    await page.locator('#tool-share-form input[name=email]').fill('friend@example.com')
    await page.locator('#tool-share-form button').click()
    await page.locator('li[id^="tool-grant-"]', { hasText: 'friend' }).waitFor({ timeout: 5000 })
      .catch(() => fail('the share did not show'))
    console.log('ok: the owner shared job-scan with friend@example.com')
  }

  if (step === 'browse') {
    await open('/tools')
    await page.locator('#tools-shared #tool-card-job-scan').waitFor({ timeout: 5000 })
      .catch(() => fail('job-scan is not under Shared with you'))
    await page.locator('#tool-card-job-scan a').click()
    await page.waitForSelector('#tool-readme')

    for (const text of ['Found', 'Closed', 'Job Scan Decision Rules', 'Build documents for cards in Generate']) {
      await page.locator('#tool-board', { hasText: text }).waitFor({ timeout: 5000 })
        .catch(() => fail(`the board section doesn't show ${text}`))
    }
    for (const skill of ['job-scan', 'job-scan-setup', 'job-scan-build']) {
      await page.locator(`#tool-skill-${skill}`).waitFor().catch(() => fail(`no skill ${skill} shown`))
    }
    await page.locator('#tool-skill-job-scan', { hasText: 'job-scan/references/linkedin.md' }).waitFor()
      .catch(() => fail('a reference file is not shown in full'))
    console.log('ok: the page shows the board and every skill file before install')
    if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/tool-page.png` })

    await page.locator('#tool-steps-claude-ai', { hasText: 'Set up Job Scan for me.' }).waitFor()
    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.locator('#tool-steps-claude-ai a', { hasText: 'job-scan-setup.zip' }).click(),
    ])
    if (download.suggestedFilename() !== 'job-scan-setup.zip') fail(`downloaded ${download.suggestedFilename()}`)
    console.log('ok: claude.ai steps download job-scan-setup.zip')

    await page.locator('#tool-client-claude_code').click()
    await page.locator('#tool-install-command', { hasText: 'slipdock tools install job-scan' }).waitFor()
    await page.locator('#tool-client-chatgpt').click()
    await page.locator('#tool-steps-chatgpt a', { hasText: 'job-scan.zip' }).waitFor()
    console.log('ok: Claude Code and ChatGPT steps are there')

    await page.locator('#tool-not-installed').waitFor().catch(() => fail('says installed before install'))
    console.log('ok: not installed yet')
  }

  if (step === 'board') {
    await open('/tools/job-scan')
    await page.locator('#tool-installed', { hasText: 'My Job Scan' }).waitFor({ timeout: 5000 })
      .catch(() => fail('the Tool page does not show the install'))
    await page.locator('#tool-installed a').click()
    await page.waitForSelector('.phx-connected')

    const lists = ['Found', 'Interested', 'Generate', 'Ready', 'Applied', 'In conversation', 'Closed']
    for (const name of lists) {
      await page.getByText(name, { exact: true }).first().waitFor({ timeout: 5000 })
        .catch(() => fail(`the board has no list ${name}`))
    }
    console.log('ok: the board has its seven lists')

    const boardId = new URL(page.url()).pathname.split('/')[2]
    await open(`/boards/${boardId}/wiki/job-scan-decision-rules`)
    await page.getByText('Head of Platform').first().waitFor({ timeout: 5000 })
      .catch(() => fail('the filled-in Decision Rules are not on the page'))
    console.log('ok: the page setup filled in reads back in the browser')
  }
} finally {
  await browser.close()
}
