// node --test assets/js — the document and window here are only what
// posthog.js touches: the meta tag, enough of the DOM for PostHog's loader
// snippet, and a window that records capture calls and event listeners.
import {test} from "node:test"
import assert from "node:assert/strict"
import {posthogConfig, installPosthog, capturePageview} from "./posthog.js"

function meta(attrs) {
  return {getAttribute: k => (k in attrs ? attrs[k] : null)}
}

// A document the loader snippet can run against: it reads the meta tag, makes a
// <script>, and inserts it before the first existing <script>.
function documentWith(metaTag) {
  const created = []
  const inserted = []
  const firstScript = {parentNode: {insertBefore: (el, _ref) => inserted.push(el)}}
  return {
    created,
    inserted,
    querySelector: sel => (sel === 'meta[name="posthog"]' ? metaTag : null),
    createElement: tag => {
      const el = {tag}
      created.push(el)
      return el
    },
    getElementsByTagName: tag => (tag === "script" ? [firstScript] : []),
  }
}

// A window that starts without posthog, records the events it is asked to
// listen for, and — once the snippet's stub is installed — records capture
// calls as the stub's method queue.
function windowWith(href) {
  return {
    posthog: undefined,
    listeners: {},
    location: {href},
    addEventListener(type, fn) {
      ;(this.listeners[type] ||= []).push(fn)
    },
  }
}

const configured = meta({
  content: "phc_abc123",
  "data-host": "https://eu.i.posthog.com",
  "data-assets": "https://eu-assets.i.posthog.com",
  "data-respect-dnt": "true",
})

// What the snippet queued for a given method name, e.g. "capture".
function queued(win, method) {
  return (win.posthog || []).filter(entry => Array.isArray(entry) && entry[0] === method)
}

test("no meta tag means no config", () => {
  assert.equal(posthogConfig(documentWith(null)), null)
})

test("a meta tag with an empty key means no config", () => {
  assert.equal(posthogConfig(documentWith(meta({content: ""}))), null)
})

test("the meta tag's key, hosts and DNT choice are read", () => {
  assert.deepEqual(posthogConfig(documentWith(configured)), {
    key: "phc_abc123",
    host: "https://eu.i.posthog.com",
    assets: "https://eu-assets.i.posthog.com",
    respectDnt: true,
  })
})

test("respect-dnt defaults to true when the attribute is absent", () => {
  const config = posthogConfig(documentWith(meta({content: "phc_abc", "data-host": "x"})))
  assert.equal(config.respectDnt, true)
})

test("respect-dnt is false only when the attribute says so", () => {
  const config = posthogConfig(
    documentWith(meta({content: "phc_abc", "data-respect-dnt": "false"})),
  )
  assert.equal(config.respectDnt, false)
})

test("without a key nothing is loaded and window.posthog is left alone", () => {
  const win = windowWith("https://app.test/")
  const doc = documentWith(null)
  assert.equal(installPosthog(win, doc), false)
  assert.equal(win.posthog, undefined)
  assert.deepEqual(doc.created, [])
})

test("with a key: init disables automatic pageviews, honours DNT, loads array.js", () => {
  const win = windowWith("https://app.test/boards")
  const doc = documentWith(configured)
  assert.equal(installPosthog(win, doc), true)

  // The snippet left a method-queue stub, so an early capture() queues rather
  // than throwing — the footgun this replaced.
  assert.equal(typeof win.posthog.capture, "function")

  const [[key, options, name]] = win.posthog._i
  assert.equal(key, "phc_abc123")
  assert.equal(name, "posthog")
  assert.equal(options.api_host, "https://eu.i.posthog.com")
  assert.equal(options.capture_pageview, false)
  assert.equal(options.respect_dnt, true)

  // The snippet injects PostHog's script from the assets host.
  const script = doc.inserted.find(el => el.tag === "script")
  assert.ok(script)
  assert.equal(script.src, "https://eu-assets.i.posthog.com/static/array.js")
})

test("the first view is captured as a $pageview on install", () => {
  const win = windowWith("https://app.test/boards")
  installPosthog(win, documentWith(configured))

  const pageviews = queued(win, "capture").filter(e => e[1] === "$pageview")
  assert.equal(pageviews.length, 1)
})

test("LiveView navigation captures one more $pageview per new view", () => {
  const win = windowWith("https://app.test/boards")
  installPosthog(win, documentWith(configured))

  const navigate = win.listeners["phx:navigate"]
  assert.equal(navigate.length, 1)

  // A navigation to a new URL captures another pageview.
  win.location.href = "https://app.test/boards/42"
  navigate[0]()
  // A spurious second phx:navigate for the same URL must not double count.
  navigate[0]()

  const pageviews = queued(win, "capture").filter(e => e[1] === "$pageview")
  assert.equal(pageviews.length, 2)
})

test("installing twice loads the script once", () => {
  const win = windowWith("https://app.test/")
  const doc = documentWith(configured)
  installPosthog(win, doc)
  const createdFirst = doc.created.length
  assert.equal(installPosthog(win, doc), false)
  assert.equal(doc.created.length, createdFirst)
})

test("respect_dnt false is passed through to init", () => {
  const win = windowWith("https://app.test/")
  const doc = documentWith(
    meta({content: "phc_abc", "data-host": "https://eu.i.posthog.com", "data-respect-dnt": "false"}),
  )
  installPosthog(win, doc)
  const [[, options]] = win.posthog._i
  assert.equal(options.respect_dnt, false)
})

test("capturePageview returns false when posthog is not present", () => {
  const win = windowWith("https://app.test/")
  assert.equal(capturePageview(win), false)
})
