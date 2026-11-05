// node --test assets/js — `<.tabs>`'s keyboard hook (#1740) against a
// stand-in DOM: only what tabs.js touches. tools/e2e/tabs.sh drives the
// real thing in Chromium.
import {test} from "node:test"
import assert from "node:assert/strict"
import {Tabs, moveTo, nextIndex, tabsOf} from "./tabs.js"

// A tablist of `n` tabs, the first in the Tab order, plus (optionally) a
// nested bar's tab that must not count.
function bar(n, {nested = false} = {}) {
  const log = []
  const listeners = {}
  const list = {
    role: "tablist",
    addEventListener: (t, f) => { (listeners[t] ||= []).push(f) },
    removeEventListener: (t, f) => { listeners[t] = (listeners[t] || []).filter(g => g !== f) },
    listeners,
  }
  const tab = (i, owner) => {
    const a = {tabindex: i === 0 ? "0" : "-1"}
    const t = {
      i,
      a,
      setAttribute: (k, v) => { a[k] = String(v) },
      closest: sel => (sel === "[role=tab]" ? t : sel === "[role=tablist]" ? owner : null),
      focus: () => log.push(["focus", i]),
      click: () => log.push(["click", i]),
    }
    return t
  }
  const tabs = Array.from({length: n}, (_, i) => tab(i, list))
  const inner = nested ? [tab(99, {role: "tablist"})] : []
  list.querySelectorAll = () => [...tabs, ...inner]
  return {list, tabs, inner, log}
}

function key(list, target, k, mods = {}) {
  let prevented = false
  const e = {key: k, target, preventDefault: () => { prevented = true }, ...mods}
  ;(list.listeners.keydown || []).forEach(f => f(e))
  return prevented
}

test("the arrows step along and wrap round the ends", () => {
  assert.equal(nextIndex("ArrowRight", 0, 3), 1)
  assert.equal(nextIndex("ArrowRight", 2, 3), 0)
  assert.equal(nextIndex("ArrowLeft", 0, 3), 2)
  assert.equal(nextIndex("ArrowLeft", 2, 3), 1)
  assert.equal(nextIndex("ArrowDown", 1, 3), 2)
  assert.equal(nextIndex("ArrowUp", 1, 3), 0)
})

test("Home and End go to the first and last tab", () => {
  assert.equal(nextIndex("Home", 2, 4), 0)
  assert.equal(nextIndex("End", 0, 4), 3)
})

test("any other key, or no tabs, is not a move", () => {
  assert.equal(nextIndex("Enter", 0, 3), null)
  assert.equal(nextIndex("a", 0, 3), null)
  assert.equal(nextIndex("ArrowRight", 0, 0), null)
  assert.equal(nextIndex("Home", 0, 0), null)
})

test("one tab: every move stays on it", () => {
  assert.equal(nextIndex("ArrowRight", 0, 1), 0)
  assert.equal(nextIndex("ArrowLeft", 0, 1), 0)
  assert.equal(nextIndex("End", 0, 1), 0)
})

test("a nested bar's tabs are not this bar's", () => {
  const {list, tabs} = bar(2, {nested: true})
  assert.deepEqual(tabsOf(list), tabs)
})

test("moveTo focuses and activates the tab and makes it the one in the Tab order", () => {
  const {tabs, log} = bar(3)
  moveTo(tabs, 2)
  assert.deepEqual(log, [["focus", 2], ["click", 2]])
  assert.deepEqual(tabs.map(t => t.a.tabindex), ["-1", "-1", "0"])
})

test("the hook moves on arrow keys, Home and End, and swallows the key", () => {
  const {list, tabs, log} = bar(3)
  const hook = {el: list}
  Tabs.mounted.call(hook)

  assert.equal(key(list, tabs[0], "ArrowRight"), true)
  assert.deepEqual(log.at(-1), ["click", 1])
  assert.equal(key(list, tabs[0], "End"), true)
  assert.deepEqual(log.at(-1), ["click", 2])
  assert.equal(key(list, tabs[2], "ArrowRight"), true)
  assert.deepEqual(log.at(-1), ["click", 0])
  assert.equal(key(list, tabs[2], "Home"), true)
  assert.deepEqual(log.at(-1), ["click", 0])
})

test("the hook leaves other keys, modified keys and non-tabs alone", () => {
  const {list, tabs, log} = bar(3)
  Tabs.mounted.call({el: list})

  assert.equal(key(list, tabs[0], "Enter"), false)
  assert.equal(key(list, tabs[0], "ArrowRight", {altKey: true}), false)
  assert.equal(key(list, tabs[0], "ArrowRight", {shiftKey: true}), false)
  assert.equal(key(list, {closest: () => null}, "ArrowRight"), false)
  assert.deepEqual(log, [])
})

test("Home on the first tab is swallowed but clicks nothing", () => {
  const {list, tabs, log} = bar(3)
  Tabs.mounted.call({el: list})
  assert.equal(key(list, tabs[0], "Home"), true)
  assert.deepEqual(log, [])
})

test("destroyed takes the listener off", () => {
  const {list, tabs, log} = bar(3)
  const hook = {el: list}
  Tabs.mounted.call(hook)
  Tabs.destroyed.call(hook)
  key(list, tabs[0], "ArrowRight")
  assert.deepEqual(log, [])
})
