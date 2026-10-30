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

test("Shift-Alt-S is search, whichever way round Shift and Caps Lock leave the letter", () => {
  assert.equal(searchHotkey({key: "S", code: "KeyS", shiftKey: true, altKey: true}), true)
  assert.equal(searchHotkey({key: "s", code: "KeyS", shiftKey: true, altKey: true}), true)
})

test("Option on a Mac changes the letter, so the key itself counts", () => {
  assert.equal(searchHotkey({key: "Í", code: "KeyS", shiftKey: true, altKey: true}), true)
  assert.equal(searchHotkey({key: "Dead", code: "KeyS", shiftKey: true, altKey: true}), true)
  assert.equal(searchHotkey({key: "Ó", code: "KeyH", shiftKey: true, altKey: true}), false)
})

test("the letter wins over the key, so a layout that moves S still works", () => {
  // Dvorak: S is typed on the key QWERTY calls ";", and "o" on KeyS.
  assert.equal(searchHotkey({key: "S", code: "Semicolon", shiftKey: true, altKey: true}), true)
  assert.equal(searchHotkey({key: "O", code: "KeyS", shiftKey: true, altKey: true}), false)
})

test("anything short of Shift-Alt-S is not search", () => {
  // Ctrl-S alone is a drawing's own save.
  assert.equal(searchHotkey({key: "s", code: "KeyS", ctrlKey: true}), false)
  // The old key, which the OS takes.
  assert.equal(searchHotkey({key: "S", code: "KeyS", ctrlKey: true, shiftKey: true}), false)
  assert.equal(searchHotkey({key: "S", code: "KeyS", metaKey: true, shiftKey: true}), false)
  assert.equal(searchHotkey({key: "S", code: "KeyS", shiftKey: true}), false)
  assert.equal(searchHotkey({key: "s", code: "KeyS", altKey: true}), false)
  // AltGr reports as Ctrl-Alt, and types a character of its own.
  assert.equal(searchHotkey({key: "S", code: "KeyS", ctrlKey: true, altKey: true, shiftKey: true}), false)
  assert.equal(searchHotkey({key: "S", code: "KeyS", metaKey: true, altKey: true, shiftKey: true}), false)
  assert.equal(searchHotkey({key: "A", code: "KeyA", shiftKey: true, altKey: true}), false)
  assert.equal(searchHotkey({shiftKey: true, altKey: true}), false)
})
