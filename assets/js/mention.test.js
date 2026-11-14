// node --test assets/js — the @mention list's word, matches and write (#2884).
import {test} from "node:test"
import assert from "node:assert/strict"
import {mentionQuery, mentionMatches, applyMention, people} from "./mention.js"

const at = text => mentionQuery(text, text.length)

test("@ opens the list with nothing typed yet, at the start or after a space", () => {
  assert.deepEqual(at("@"), {start: 0, text: ""})
  assert.deepEqual(at("Ping @"), {start: 5, text: ""})
  assert.deepEqual(at("(@"), {start: 1, text: ""})
})

test("the word after the @ is the query, in lower case", () => {
  assert.deepEqual(at("Ping @Ada"), {start: 5, text: "ada"})
  assert.deepEqual(at("cc @a.b-c_d"), {start: 3, text: "a.b-c_d"})
})

test("an email address, a path, a doubled @ or a space closes it", () => {
  assert.equal(at("mail ada@example.com"), null)
  assert.equal(at("see /team/@ada"), null)
  assert.equal(at("@@ada"), null)
  assert.equal(at("Ping @ada now"), null)
  assert.equal(at("no at sign"), null)
  assert.equal(at("@" + "x".repeat(63)), null, "longer than a handle can be")
  assert.deepEqual(at("@" + "x".repeat(62)), {start: 0, text: "x".repeat(62)})
})

test("the caret, not the end of the text, is where the query ends", () => {
  const text = "Ping @ad and more"
  assert.deepEqual(mentionQuery(text, 8), {start: 5, text: "ad"})
  assert.equal(mentionQuery(text, 3), null)
})

const team = [
  {handle: "ada", name: "Ada Lovelace", email: "ada@example.com"},
  {handle: "grace", name: "Grace Hopper", email: "gh@example.com"},
  {handle: "x", name: null, email: "nobody@example.com"},
]

test("a person matches on handle, email or any one name, from its start", () => {
  assert.deepEqual(mentionMatches(team, "ada").map(p => p.handle), ["ada"])
  assert.deepEqual(mentionMatches(team, "hop").map(p => p.handle), ["grace"], "a second name")
  assert.deepEqual(mentionMatches(team, "gh").map(p => p.handle), ["grace"], "the email")
  assert.deepEqual(mentionMatches(team, "nob").map(p => p.handle), ["x"], "no name at all")
  assert.deepEqual(mentionMatches(team, "ove"), [], "not from the middle of a word")
  assert.equal(mentionMatches(team, "").length, 3, "an empty word offers everyone")
})

test("eight people at most", () => {
  const many = Array.from({length: 12}, (_, i) => ({handle: "p" + i, name: "", email: ""}))
  assert.equal(mentionMatches(many, "p").length, 8)
})

test("taking a person writes @handle and a space over @word, caret after it", () => {
  assert.deepEqual(applyMention("Ping @ad now", 5, 8, {handle: "ada"}), {value: "Ping @ada  now", caret: 10})
  assert.deepEqual(applyMention("@", 0, 1, {handle: "grace"}), {value: "@grace ", caret: 7})
})

test("the people come from data-people, and bad JSON gives nobody", () => {
  assert.deepEqual(people({dataset: {people: JSON.stringify(team)}}), team)
  assert.deepEqual(people({dataset: {people: "{not json"}}), [])
  assert.deepEqual(people({dataset: {}}), [])
})
