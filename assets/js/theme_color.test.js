// node --test assets/js — the loading bar and theme-color follow the tokens (#1702).
import {test} from "node:test"
import assert from "node:assert/strict"
import {token, topbarOptions, syncThemeColor} from "./theme_color.js"

const reader = values => name => values[name] || ""

function fakeDocument(withMeta) {
  const head = {children: [], appendChild(el) { this.children.push(el) }}
  const element = () => {
    const attrs = {}
    return {attrs, setAttribute: (k, v) => { attrs[k] = v }, getAttribute: k => attrs[k]}
  }
  const meta = withMeta ? element() : null
  if (meta) { meta.setAttribute("name", "theme-color"); meta.setAttribute("content", "#000000") }
  return {
    head,
    documentElement: {},
    createElement: () => element(),
    querySelector: sel => {
      assert.equal(sel, 'meta[name="theme-color"]')
      return meta || head.children.find(el => el.attrs.name === "theme-color") || null
    },
    meta,
  }
}

test("token reads the custom property, trimmed", () => {
  const root = {}
  const style = el => {
    assert.equal(el, root)
    return {getPropertyValue: name => (name === "--color-primary" ? "  #1A6E7C " : "")}
  }
  assert.equal(token("primary", root, style), "#1A6E7C")
  assert.equal(token("accent", root, style), "")
})

test("the loading bar is the primary, with no shadow", () => {
  assert.deepEqual(topbarOptions(reader({primary: "#5FB3C1"})), {barColors: {0: "#5FB3C1"}, shadowBlur: 0})
})

test("with no primary yet, the bar keeps topbar's own colours", () => {
  const options = topbarOptions(reader({}))
  assert.equal(options.barColors, undefined)
  assert.equal(options.shadowBlur, 0)
})

test("theme-color takes base-100, on the meta that is there", () => {
  const doc = fakeDocument(true)
  assert.equal(syncThemeColor(doc, reader({"base-100": "#16304A"})), "#16304A")
  assert.equal(doc.meta.getAttribute("content"), "#16304A")
  assert.equal(doc.head.children.length, 0)
})

test("theme-color makes the meta when the page has none, and reuses it after", () => {
  const doc = fakeDocument(false)
  syncThemeColor(doc, reader({"base-100": "#FFFFFF"}))
  syncThemeColor(doc, reader({"base-100": "#16304A"}))
  assert.equal(doc.head.children.length, 1)
  assert.equal(doc.head.children[0].getAttribute("name"), "theme-color")
  assert.equal(doc.head.children[0].getAttribute("content"), "#16304A")
})

test("theme-color is left alone when there is no token", () => {
  const doc = fakeDocument(true)
  assert.equal(syncThemeColor(doc, reader({})), null)
  assert.equal(doc.meta.getAttribute("content"), "#000000")
})
