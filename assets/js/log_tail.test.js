// node --test assets/js — a job's live log (#1871) follows new lines only
// while its reader is at the bottom.
import {test} from "node:test"
import assert from "node:assert/strict"
import {LogTail, NEAR, atBottom} from "./log_tail.js"

function box({scrollHeight = 1000, clientHeight = 200, scrollTop = 800} = {}) {
  const listeners = {}
  return {
    scrollHeight, clientHeight, scrollTop,
    addEventListener: (name, fn) => { listeners[name] = fn },
    removeEventListener: name => { delete listeners[name] },
    listeners,
  }
}

test("atBottom allows a few pixels short of the end", () => {
  assert.equal(atBottom(box({scrollTop: 800})), true)
  assert.equal(atBottom(box({scrollTop: 800 - NEAR})), true)
  assert.equal(atBottom(box({scrollTop: 800 - NEAR - 1})), false)
})

test("the log opens at its newest line and follows new ones", () => {
  const el = box({scrollTop: 0})
  const hook = {el, ...LogTail}
  hook.mounted()
  assert.equal(el.scrollTop, 1000)

  el.scrollTop = 800
  hook.beforeUpdate()
  el.scrollHeight = 1400
  hook.updated()
  assert.equal(el.scrollTop, 1400)
})

test("a reader scrolled up is left where they are", () => {
  const el = box()
  const hook = {el, ...LogTail}
  hook.mounted()
  el.scrollTop = 100
  el.listeners.scroll()
  hook.beforeUpdate()
  el.scrollHeight = 1400
  hook.updated()
  assert.equal(el.scrollTop, 100)
  hook.destroyed()
  assert.equal(el.listeners.scroll, undefined)
})
