// node --test assets/js — where a dropdown's menu opens (#1926).
import {test} from "node:test"
import assert from "node:assert/strict"
import {menuOffset} from "./dropdown_align.js"

const button = (left, w = 28) => ({left, right: left + w})

test("start-aligned under the button when the menu fits", () => {
  assert.equal(menuOffset(button(100), 288, 1280), 0)
})

test("end-aligned when start-aligned would run off the right", () => {
  // 1100 + 288 > 1272: right edges line up, as dropdown-end did.
  assert.equal(menuOffset(button(1100), 288, 1280), 28 - 288)
})

test("on a phone with room on neither side it is held on screen (the #1926 case)", () => {
  // Button at 194–222 on a 390px screen: start-aligned ends at 482, end-aligned
  // starts at -66. It moves right just far enough to clear the margin.
  const left = 194 + menuOffset(button(194), 288, 390)
  assert.equal(left, 8)
  assert.ok(left >= 8 && left + 288 <= 382)
})

test("a button near the left edge never pushes the menu off the left", () => {
  assert.equal(2 + menuOffset(button(2), 288, 390), 8)
})

test("a menu as wide as the screen allows sits at the margin", () => {
  assert.equal(150 + menuOffset(button(150), 374, 390), 8)
})

test("a menu wider than the screen keeps its left edge on screen", () => {
  assert.equal(150 + menuOffset(button(150), 500, 390), 8)
})
