// Run with: node --test assets/js/hint_labels.test.js
import {test} from "node:test"
import assert from "node:assert/strict"
import {HINT_CHARS, hintLabels, narrowHints, typeHint} from "./hint_labels.js"

// The pairs of labels where one begins the other: typing the shorter would
// pick it before the longer could be finished.
const prefixPairs = labels => {
  const sorted = [...labels].sort()
  const pairs = []
  // Sorted, a label's extensions come straight after it.
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i].startsWith(sorted[i - 1])) pairs.push([sorted[i - 1], sorted[i]])
  }
  return pairs
}

// Types `keys` one at a time from nothing typed, as BoardKeys does.
const typeAll = (labels, keys) =>
  keys.reduce((state, key) => (state.picked === null ? narrowHints(labels, state.typed, key) : state), {
    typed: "",
    remaining: labels,
    picked: null,
  })

test("there are 26 label letters, none twice, the home row first", () => {
  assert.equal(HINT_CHARS.length, 26)
  assert.equal(new Set(HINT_CHARS).size, 26)
  assert.deepEqual(HINT_CHARS.slice(0, 4), ["a", "s", "d", "f"])
})

test("no targets get no labels, and a few get the first letters", () => {
  assert.deepEqual(hintLabels(0), [])
  assert.deepEqual(hintLabels(1), ["a"])
  assert.deepEqual(hintLabels(3), ["a", "s", "d"])
})

test("26 targets get the 26 single letters", () => {
  assert.deepEqual(hintLabels(26), HINT_CHARS)
})

test("27 targets give up one letter to make pairs of it", () => {
  const labels = hintLabels(27)
  assert.equal(labels.length, 27)
  // "a" is spent as a prefix, so it is no label itself.
  assert.deepEqual(labels.slice(0, 25), HINT_CHARS.slice(1))
  assert.deepEqual(labels.slice(25), ["aa", "as"])
  assert.equal(labels.includes("a"), false)
})

test("700 targets, more than there are pairs, go on to three letters", () => {
  const labels = hintLabels(700)
  const lengths = new Set(labels.map(l => l.length))
  assert.deepEqual([...lengths].sort(), [2, 3])
  // "a" is spent as a three-letter prefix's start: "aa" is no label, "aaa" is.
  assert.equal(labels.includes("aa"), false)
  assert.equal(labels.includes("aaa"), true)
})

for (const count of [26, 27, 51, 52, 676, 677, 700]) {
  test(`${count} targets get ${count} labels, each unique and none another's prefix`, () => {
    const labels = hintLabels(count)
    assert.equal(labels.length, count)
    assert.equal(new Set(labels).size, count)
    assert.deepEqual(prefixPairs(labels), [])
    for (const label of labels) {
      assert.ok(label.length > 0, "an empty label")
      assert.ok([...label].every(c => HINT_CHARS.includes(c)), label)
    }
  })

  test(`every one of ${count} labels, typed in full, picks itself and nothing sooner`, () => {
    const labels = hintLabels(count)
    for (const label of labels) {
      const before = typeAll(labels, [...label.slice(0, -1)])
      assert.equal(before.picked, null, label)
      assert.equal(typeAll(labels, [...label]).picked, label)
    }
  })
}

test("the prefix check itself catches a label that begins another", () => {
  assert.deepEqual(prefixPairs(["s", "a", "as"]), [["a", "as"]])
  assert.deepEqual(prefixPairs(["s", "aa", "as"]), [])
})

test("a single-letter label is picked by its letter", () => {
  const labels = hintLabels(27)
  assert.deepEqual(narrowHints(labels, "", "s"), {typed: "s", remaining: ["s"], picked: "s"})
})

test("the first letter of a pair narrows to the pairs and picks nothing", () => {
  const labels = hintLabels(27)
  assert.deepEqual(narrowHints(labels, "", "a"), {typed: "a", remaining: ["aa", "as"], picked: null})
})

test("the second letter of a pair picks it", () => {
  const labels = hintLabels(27)
  assert.deepEqual(narrowHints(labels, "a", "s"), {typed: "as", remaining: ["as"], picked: "as"})
})

test("a capital is its letter", () => {
  const labels = hintLabels(27)
  assert.deepEqual(narrowHints(labels, "", "A"), narrowHints(labels, "", "a"))
  assert.equal(narrowHints(labels, "a", "S").picked, "as")
})

test("a letter no label goes on with changes nothing", () => {
  const labels = hintLabels(27)
  // "ad" is no label of 27: only "aa" and "as" follow "a".
  assert.deepEqual(narrowHints(labels, "a", "d"), {typed: "a", remaining: ["aa", "as"], picked: null})
  // With three targets, "f" is no label at all.
  assert.deepEqual(narrowHints(hintLabels(3), "", "f"), {typed: "", remaining: ["a", "s", "d"], picked: null})
})

test("a key that is no label letter changes nothing", () => {
  const labels = hintLabels(27)
  for (const key of ["1", " ", ";", "Enter", "Tab", "ArrowDown", "Shift", "é"]) {
    assert.deepEqual(narrowHints(labels, "a", key), {typed: "a", remaining: ["aa", "as"], picked: null}, key)
  }
})

test("only the label letters are typed, whatever the labels given", () => {
  // Not what hintLabels gives, but what the code says: a digit or a key's
  // name is never added, even where a label would go on with it.
  assert.deepEqual(narrowHints(["1", "a"], "", "1"), {typed: "", remaining: ["1", "a"], picked: null})
  assert.deepEqual(narrowHints(["Enter", "a"], "", "Enter"), {typed: "", remaining: ["Enter", "a"], picked: null})
})

test("Backspace takes the last letter back and brings its labels back", () => {
  const labels = hintLabels(27)
  assert.deepEqual(narrowHints(labels, "a", "Backspace"), {typed: "", remaining: labels, picked: null})

  const many = hintLabels(700)
  const two = narrowHints(many, "aa", "Backspace")
  assert.equal(two.typed, "a")
  assert.equal(two.picked, null)
  assert.deepEqual(two.remaining, many.filter(l => l.startsWith("a")))
  assert.ok(two.remaining.length > 1)
})

test("Backspace with nothing typed leaves nothing typed and every label", () => {
  const labels = hintLabels(27)
  assert.deepEqual(narrowHints(labels, "", "Backspace"), {typed: "", remaining: labels, picked: null})
})

test("Backspace never picks, even when one label is left", () => {
  // One target: its label "a" is all that remains, typed or not.
  assert.deepEqual(narrowHints(["a"], "", "Backspace"), {typed: "", remaining: ["a"], picked: null})
})

test("a mistyped letter, taken back, still reaches the label meant", () => {
  const labels = hintLabels(27)
  assert.equal(typeAll(labels, ["a", "d", "Backspace", "a", "a"]).picked, "aa")
})

test("one label left that is longer than what is typed is not picked yet", () => {
  // Not what hintLabels gives, but what the code says: a pick is a label
  // typed in full, not merely the last one standing.
  assert.deepEqual(narrowHints(["as", "sd"], "", "a"), {typed: "a", remaining: ["as"], picked: null})
})

test("a label that begins another, if it were given, could never be picked", () => {
  // Why hintLabels must stay prefix-free: "a" is typed in full but "as" is
  // still in the running, so only the longer one can be reached.
  assert.deepEqual(narrowHints(["a", "as"], "", "a"), {typed: "a", remaining: ["a", "as"], picked: null})
  assert.equal(narrowHints(["a", "as"], "a", "s").picked, "as")
})

// BoardKeys as far as typeHint goes: the labelled targets, what is typed, and
// a record of what it painted and picked.
const board = (count, typed = "") => {
  const b = {
    hints: hintLabels(count).map((label, i) => ({label, id: `card-${i}`})),
    typed,
    painted: [],
    picked: [],
    paint: () => b.painted.push(b.typed),
    pick: id => b.picked.push(id),
  }
  return b
}

test("typing a whole label picks its target, by id, and paints nothing", () => {
  const b = board(27)
  typeHint(b, "a")
  typeHint(b, "s")
  // "as" is the last of 27 labels.
  assert.equal(b.hints[26].label, "as")
  assert.deepEqual(b.picked, ["card-26"])
  // The first letter was painted; the pick was not.
  assert.deepEqual(b.painted, ["a"])
})

test("a single letter picks at once", () => {
  const b = board(3)
  typeHint(b, "D")
  assert.deepEqual(b.picked, ["card-2"])
  assert.deepEqual(b.painted, [])
})

test("a key that matches nothing picks nothing and leaves what was typed", () => {
  const b = board(27, "a")
  for (const key of ["d", "1", "Enter"]) typeHint(b, key)
  assert.equal(b.typed, "a")
  assert.deepEqual(b.picked, [])
  assert.deepEqual(b.painted, ["a", "a", "a"])
})

test("Backspace takes a letter back, repaints and picks nothing", () => {
  const b = board(27, "a")
  typeHint(b, "Backspace")
  assert.equal(b.typed, "")
  assert.deepEqual(b.painted, [""])
  assert.deepEqual(b.picked, [])
})
