// node --test assets/js — the @mention list's word, matches and write (#2884).
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {Mention, mentionQuery, mentionMatches, applyMention, people} from "./mention.js"
import {fakeDom, mountHook, type, key, links, active} from "./caret_menu_fake_dom.js"

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

// Mention as built: the hook app.js registers, mounted on a wrapper with data-people.
let body
beforeEach(() => { ({body} = fakeDom()) })

const mountMention = (value, people = team) =>
  mountHook(Mention, value, {dataset: {people: JSON.stringify(people)}, body})

const shown = menu => links(menu).map(a => a.children.map(s => s.textContent))

test("Mention: its list is on <body>, marked and 256px wide", () => {
  const {menu} = mountMention("")
  assert.deepEqual(menu.dataset, {mentionMenu: ""})
  assert.equal(menu.style.width, "256px")
  assert.equal(menu.classList.contains("hidden"), true)
})

test("Mention: typing @ad lists the matching people from data-people", () => {
  const {ta, menu} = mountMention("")
  type(ta, "Ping @ad")
  assert.equal(menu.classList.contains("hidden"), false)
  assert.deepEqual(shown(menu), [["Ada Lovelace", "@ada"]])
  assert.equal(active(menu), 0)
  type(ta, "Ping @")
  assert.deepEqual(shown(menu), [["Ada Lovelace", "@ada"], ["Grace Hopper", "@grace"], ["nobody@example.com", "@x"]],
    "a person with no name shows their email")
})

test("Mention: an email address opens nothing", () => {
  const {ta, menu} = mountMention("")
  type(ta, "mail ada@ex")
  assert.equal(menu.classList.contains("hidden"), true)
})

test("Mention: Enter on a row writes @handle and a space, and tells the form", () => {
  const {ta, el, menu} = mountMention("")
  type(ta, "Ping @ad now", 8)
  ta.sent.length = 0
  el.fire("keydown", key("Enter"))
  assert.equal(ta.value, "Ping @ada  now")
  assert.equal(ta.selectionStart, 10)
  assert.deepEqual(ta.sent, ["input"])
  assert.equal(menu.classList.contains("hidden"), true)
})

test("Mention: a click on the second row writes that person", () => {
  const {ta, menu} = mountMention("")
  type(ta, "@")
  links(menu)[1].fire("mousedown", {preventDefault() {}})
  assert.equal(ta.value, "@grace ")
})

test("Mention: no data-people, or bad JSON, lists nobody", () => {
  for (const people of [undefined, "{not json"]) {
    const {ta, menu} = mountHook(Mention, "", {dataset: people === undefined ? {} : {people}, body})
    type(ta, "@a")
    assert.equal(menu.children.length, 0)
    assert.equal(menu.classList.contains("hidden"), true)
  }
})
