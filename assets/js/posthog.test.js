// node --test assets/js — the document here is only what posthog.js touches.
import {test} from "node:test"
import assert from "node:assert/strict"
import {posthogConfig, installPosthog} from "./posthog.js"

function documentWith(meta) {
  const appended = []
  return {
    appended,
    querySelector: sel => (sel === 'meta[name="posthog"]' ? meta : null),
    createElement: tag => ({tag}),
    head: {appendChild: el => appended.push(el)},
  }
}

function meta(attrs) {
  return {getAttribute: k => (k in attrs ? attrs[k] : null)}
}

const configured = meta({
  content: "phc_abc123",
  "data-host": "https://eu.i.posthog.com",
  "data-assets": "https://eu-assets.i.posthog.com",
})

test("no meta tag means no config", () => {
  assert.equal(posthogConfig(documentWith(null)), null)
})

test("a meta tag with an empty key means no config", () => {
  assert.equal(posthogConfig(documentWith(meta({content: ""}))), null)
})

test("the meta tag's key and hosts are read", () => {
  assert.deepEqual(posthogConfig(documentWith(configured)), {
    key: "phc_abc123",
    host: "https://eu.i.posthog.com",
    assets: "https://eu-assets.i.posthog.com",
  })
})

test("without a key nothing is loaded and window.posthog is left alone", () => {
  const win = {}
  const doc = documentWith(null)
  assert.equal(installPosthog(win, doc), false)
  assert.equal(win.posthog, undefined)
  assert.deepEqual(doc.appended, [])
})

test("with a key, a snippet stub is queued and PostHog's script is loaded", () => {
  const win = {}
  const doc = documentWith(configured)
  assert.equal(installPosthog(win, doc), true)

  assert.equal(win.posthog.__SV, 1)
  assert.deepEqual(win.posthog.people, [])
  const [[key, options, name]] = win.posthog._i
  assert.equal(key, "phc_abc123")
  assert.equal(name, "posthog")
  assert.equal(options.api_host, "https://eu.i.posthog.com")
  assert.equal(options.respect_dnt, true)

  assert.equal(doc.appended.length, 1)
  const [script] = doc.appended
  assert.equal(script.tag, "script")
  assert.equal(script.async, true)
  assert.equal(script.src, "https://eu-assets.i.posthog.com/static/array.js")
})

test("installing twice loads the script once", () => {
  const win = {}
  const doc = documentWith(configured)
  installPosthog(win, doc)
  assert.equal(installPosthog(win, doc), false)
  assert.equal(doc.appended.length, 1)
})
