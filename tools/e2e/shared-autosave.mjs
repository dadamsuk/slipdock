// Driven by shared-autosave.sh: see there for what it proves.
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const searchPaths = (process.env.NODE_PATH || '').split(':').filter(Boolean)
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd(), ...searchPaths] }))

const [link, base, id] = process.argv.slice(2)
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

await page.goto(`${base}/shared/pages/${id}/edit`)
await connected()

await page.evaluate(b64 => {
  const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0))
  const data = new DataTransfer()
  data.items.add(new File([bytes], "shot.png", {type: "image/png"}))
  const target = document.querySelector("#shared-body-paste")
  target.dispatchEvent(new ClipboardEvent("paste", {clipboardData: data, bubbles: true, cancelable: true}))
}, png)
await page.waitForFunction(
  () => document.querySelector("#page_body").value.includes("/attachments/"),
  null, {timeout: 15000}
)

// Typed into the Markdown editor, which stands in for the textarea.
await page.click(".cm-content")
await page.keyboard.press("Control+End")
await page.keyboard.type("Typed in the browser")
await page.waitForSelector("#autosave-status", {timeout: 15000})

// Reload: the work is on the list, and comes back from it.
await page.goto(`${base}/shared`)
await connected()
await page.click("#unsaved-pages a:has-text('Their plan')")
await page.waitForSelector("#autosave-restored")
await connected()
const body = await page.inputValue("#page_body")
if (!body.includes("Typed in the browser") || !body.includes("/attachments/"))
  throw new Error("body not restored: " + body)

await page.click("#shared-edit-form button[type=submit]")
await page.waitForURL(new RegExp(`/shared/pages/${id}$`))
await page.waitForSelector(".wiki-prose img[src*='/attachments/']")
const kept = await page.$eval(".wiki-prose img", img => img.complete && img.naturalWidth > 0)
if (!kept) throw new Error("the image didn't load on the saved page")
if (failures.length) throw new Error(failures.join("\n"))

console.log("ok: pasted, typed, picked up from Unsaved work, saved")
await browser.close()
