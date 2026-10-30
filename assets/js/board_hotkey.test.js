// node --test assets/js
import {test} from "node:test"
import assert from "node:assert/strict"
import {boardHotkey, searchHotkey} from "./board_hotkey.js"

const key = (code, mods = {}) => ({code, ctrlKey: true, shiftKey: true, ...mods})

test("Ctrl-Shift and a top-row digit is that digit, whatever character Shift makes", () => {
  assert.equal(boardHotkey({...key("Digit1"), key: "!"}), "1")
  assert.equal(boardHotkey({...key("Digit0"), key: ")"}), "0")
  assert.equal(boardHotkey({...key("Digit3"), key: "£"}), "3")
})

test("the number pad counts, and Cmd stands in for Ctrl", () => {
  assert.equal(boardHotkey(key("Numpad7")), "7")
  assert.equal(boardHotkey(key("Digit5", {ctrlKey: false, metaKey: true})), "5")
})

test("anything short of Ctrl-Shift-digit is not a hotkey", () => {
  assert.equal(boardHotkey(key("Digit1", {shiftKey: false})), null)
  assert.equal(boardHotkey(key("Digit1", {ctrlKey: false})), null)
  assert.equal(boardHotkey(key("Digit1", {altKey: true})), null)
  assert.equal(boardHotkey(key("KeyA")), null)
  assert.equal(boardHotkey(key("NumpadAdd")), null)
  assert.equal(boardHotkey({ctrlKey: true, shiftKey: true}), null)
})

test("Ctrl-Shift-S is search, whichever way round Shift and Caps Lock leave the letter", () => {
  assert.equal(searchHotkey({key: "S", ctrlKey: true, shiftKey: true}), true)
  assert.equal(searchHotkey({key: "s", ctrlKey: true, shiftKey: true}), true)
})

test("Cmd stands in for Ctrl on search too", () => {
  assert.equal(searchHotkey({key: "S", metaKey: true, shiftKey: true}), true)
})

test("anything short of Ctrl-Shift-S is not search", () => {
  // Ctrl-S alone is a drawing's own save.
  assert.equal(searchHotkey({key: "s", ctrlKey: true}), false)
  assert.equal(searchHotkey({key: "S", shiftKey: true}), false)
  assert.equal(searchHotkey({key: "S", ctrlKey: true, shiftKey: true, altKey: true}), false)
  assert.equal(searchHotkey({key: "A", ctrlKey: true, shiftKey: true}), false)
  assert.equal(searchHotkey({ctrlKey: true, shiftKey: true}), false)
})
