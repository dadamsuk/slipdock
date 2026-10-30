// Driven by wiki-autosave.sh: see there for what it proves.
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [link, base, board] = process.argv.slice(2)
const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox'],
})
const page = await browser.newPage()
const failures = []
// A hook pushing from `mounted` during a live navigation logs this and goes on.
page.on("pageerror", e => {
  if (!e.message.includes("LiveView not connected")) failures.push(e.message)
})

const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
const connected = () => page.waitForSelector("[data-phx-main].phx-connected")

await page.goto(link)
await page.click("button[type=submit]")
await page.waitForLoadState("networkidle")

await page.goto(`${base}/boards/${board}/wiki/new`)
await connected()

// Paste before a title exists: the old editor refused, or fell over.
await page.evaluate(b64 => {
  const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0))
  const data = new DataTransfer()
  data.items.add(new File([bytes], "shot.png", {type: "image/png"}))
  const target = document.querySelector("#page-body-paste")
  target.dispatchEvent(new ClipboardEvent("paste", {clipboardData: data, bubbles: true, cancelable: true}))
}, png)

await page.waitForFunction(
  () => document.querySelector("#page_body").value.includes("/autosave-files/"),
  null, {timeout: 15000}
)
await page.waitForSelector("#page-preview img[src*='/autosave-files/']")
const shown = await page.$eval("#page-preview img", img => img.complete && img.naturalWidth > 0)
if (!shown) throw new Error("the held image didn't load in the preview")

await page.fill("#new-page-title", "Pasted first")
await page.waitForSelector("#autosave-status", {timeout: 15000})
await page.waitForTimeout(3500)

// Reload: the editor starts blank, and the work is on the list.
await page.reload()
await connected()
await page.click("#unsaved-pages a:has-text('Pasted first')")
await page.waitForSelector("#autosave-restored")
await connected()
if ((await page.inputValue("#new-page-title")) !== "Pasted first") throw new Error("title not restored")
const body = await page.inputValue("#page_body")
if (!body.includes("/autosave-files/")) throw new Error("body not restored: " + body)

await page.click("#page-form button[type=submit]")
await page.waitForURL(/wiki\/pasted-first$/)
await page.waitForSelector(".wiki-prose img[src*='/attachments/']")
const kept = await page.$eval(".wiki-prose img", img => img.complete && img.naturalWidth > 0)
if (!kept) throw new Error("the attached image didn't load on the saved page")
if (failures.length) throw new Error(failures.join("\n"))

console.log("ok: pasted, held, restored after a reload, attached on Save")
await browser.close()
