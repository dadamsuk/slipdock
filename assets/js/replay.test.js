// node --test assets/js — the parts of the replay hook that are arithmetic.
import {test} from "node:test"
import assert from "node:assert/strict"
import {clock, spanLabel, peaks, spanBox, pastEnd} from "./replay.js"

test("a passage reads as minutes and seconds, and hours when it needs them", () => {
  assert.equal(clock(458_000), "7:38")
  assert.equal(clock(3_725_000), "1:02:05")
  assert.equal(clock(-5), "0:00")
  assert.equal(spanLabel(458_000, 464_000), "7:38–7:44")
})

test("peaks are the loudest sample in each slice", () => {
  assert.deepEqual(peaks([0.1, -0.9, 0.2, 0.3, -0.4, 0.05], 3), [0.9, 0.3, 0.4])
  assert.deepEqual(peaks([], 4), [0, 0, 0, 0])
  assert.deepEqual(peaks([0.5], 2).length, 2)
})

test("the passage is marked where it sits on the strip", () => {
  assert.deepEqual(spanBox(30_000, 60_000, 120_000, 400), {x: 100, w: 100})
  assert.deepEqual(spanBox(0, 10, 0, 400), {x: 0, w: 0})
  assert.equal(spanBox(119_999, 130_000, 120_000, 400).x <= 400, true)
})

test("playback past the passage's end is noticed", () => {
  assert.equal(pastEnd(464_000, 464_000), true)
  assert.equal(pastEnd(463_999, 464_000), false)
})
