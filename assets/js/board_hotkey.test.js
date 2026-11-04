// node --test assets/js
import {test} from "node:test"
import assert from "node:assert/strict"
import {boardHotkey, noteHotkey, placeHotkey, searchHotkey} from "./board_hotkey.js"

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

test("Shift-Alt-N is a quick note, by the letter or, on a Mac, the key", () => {
  const mods = {shiftKey: true, altKey: true}
  assert.equal(noteHotkey({key: "N", code: "KeyN", ...mods}), true)
  assert.equal(noteHotkey({key: "˜", code: "KeyN", ...mods}), true)
  assert.equal(noteHotkey({key: "S", code: "KeyS", ...mods}), false)
  assert.equal(searchHotkey({key: "N", code: "KeyN", ...mods}), false)
})

test("Shift-Alt-N stands down with Ctrl or Cmd held, or AltGr", () => {
  const mods = {key: "N", code: "KeyN", shiftKey: true, altKey: true}
  assert.equal(noteHotkey({...mods, ctrlKey: true}), false)
  assert.equal(noteHotkey({...mods, metaKey: true}), false)
  assert.equal(noteHotkey({...mods, shiftKey: false}), false)
})

test("Shift-Alt-F is Favourites and Shift-Alt-A is Ask, by letter or by key on a Mac", () => {
  assert.equal(placeHotkey({key: "F", code: "KeyF", shiftKey: true, altKey: true}), "favourites")
  assert.equal(placeHotkey({key: "a", code: "KeyA", shiftKey: true, altKey: true}), "ask")
  assert.equal(placeHotkey({key: "Ï", code: "KeyF", shiftKey: true, altKey: true}), "favourites")
  assert.equal(placeHotkey({key: "Å", code: "KeyA", shiftKey: true, altKey: true}), "ask")
})

test("anything short of Shift-Alt with F or A is not a place key", () => {
  assert.equal(placeHotkey({key: "F", code: "KeyF", shiftKey: true}), null)
  assert.equal(placeHotkey({key: "f", code: "KeyF", altKey: true}), null)
  assert.equal(placeHotkey({key: "F", code: "KeyF", shiftKey: true, altKey: true, ctrlKey: true}), null)
  assert.equal(placeHotkey({key: "S", code: "KeyS", shiftKey: true, altKey: true}), null)
})
