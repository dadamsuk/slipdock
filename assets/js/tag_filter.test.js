// node --test assets/js
import {test} from "node:test"
import assert from "node:assert/strict"
import {matches, narrow} from "./tag_filter.js"

test("nothing typed matches every tag", () => {
  assert.equal(matches("Bug", ""), true)
  assert.equal(matches("Bug", "   "), true)
  assert.equal(matches("Bug", undefined), true)
})

test("a match ignores case and the space around what is typed", () => {
  assert.equal(matches("Backend", "END"), true)
  assert.equal(matches("Backend", "  back "), true)
  assert.equal(matches("Backend", "front"), false)
})

test("narrow shows the matches, and offers a new tag only when no tag has that name", () => {
  const names = ["Bug", "Backend", "Design"]

  assert.deepEqual(narrow(names, ""), {shown: [true, true, true], none: false, offer: null})
  assert.deepEqual(narrow(names, "b"), {shown: [true, true, false], none: false, offer: "b"})
  // The exact name, in any case, is that tag: nothing new to offer.
  assert.deepEqual(narrow(names, "bug"), {shown: [true, false, false], none: false, offer: null})
  assert.deepEqual(narrow(names, " Urgent "), {shown: [false, false, false], none: true, offer: "Urgent"})
})

test("a board with no tags offers whatever is typed", () => {
  assert.deepEqual(narrow([], "First"), {shown: [], none: true, offer: "First"})
  assert.deepEqual(narrow([], ""), {shown: [], none: false, offer: null})
})
