// node --test assets/js
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {PageLink, linkQuery, applyLink, suggestPages} from "./page_link.js"
import {fakeDom, mountHook, type, key, links, active} from "./caret_menu_fake_dom.js"

const at = text => linkQuery(text, text.length)

test("[[ opens the picker with nothing typed yet", () => {
  assert.deepEqual(at("See [["), {start: 4, text: ""})
  assert.deepEqual(at("[["), {start: 0, text: ""})
})

test("what follows the brackets is the query: a title, a folder, a code", () => {
  assert.deepEqual(at("See [[Retry pol"), {start: 4, text: "Retry pol"})
  assert.deepEqual(at("x [[Design/Bil"), {start: 2, text: "Design/Bil"}, "folder, then title")
  assert.deepEqual(at("x [[W-19"), {start: 2, text: "W-19"})
  assert.deepEqual(at("an embed ![[Dia"), {start: 10, text: "Dia"})
})

test("a closed link, a new line, a label or an anchor closes it", () => {
  assert.equal(at("See [[Retry policy]] and"), null)
  assert.equal(at("See [[Retry\npolicy"), null)
  assert.equal(at("See [[Retry policy|how"), null)
  assert.equal(at("See [[Retry policy#Back"), null)
  assert.equal(at("one [ bracket"), null)
  assert.equal(at("[[" + "x".repeat(81)), null)
})

test("the caret, not the end of the text, is where the query ends", () => {
  const text = "See [[Ret and more"
  assert.deepEqual(linkQuery(text, 9), {start: 4, text: "Ret"})
  assert.equal(linkQuery(text, 2), null)
})

test("taking a page writes the link over [[word, caret after it", () => {
  assert.deepEqual(applyLink("See [[ret now", 4, 9, "[[Retry policy]]"),
    {value: "See [[Retry policy]] now", caret: 20})
})

test("brackets the editor closed already are taken in, not doubled", () => {
  assert.deepEqual(applyLink("See [[ret]] now", 4, 9, "[[W-31]]"), {value: "See [[W-31]] now", caret: 12})
  assert.deepEqual(applyLink("See [[ret] now", 4, 9, "[[W-31]]"), {value: "See [[W-31]] now", caret: 12})
})

test("the pages are asked of the server with the word, the board and fresh", async () => {
  const sent = []
  const hook = {
    el: {dataset: {board: "3"}},
    pushEvent: (name, payload, reply) => { sent.push({name, payload}); reply({pages: [{code: "W-1"}]}) },
  }
  assert.deepEqual(await suggestPages(hook, {text: "Ret"}, {fresh: true}), [{code: "W-1"}])
  assert.deepEqual(sent, [{name: "page_link_suggest", payload: {q: "Ret", board: "3", fresh: true}}])
})

test("no board and no reply still ask and answer: with no pages", async () => {
  const hook = {el: {dataset: {}}, pushEvent: (_n, payload, reply) => { assert.equal(payload.board, ""); reply(null) }}
  assert.deepEqual(await suggestPages(hook, {text: ""}, {fresh: false}), [])
})

test("a later keystroke in the word is sent as not fresh", async () => {
  const sent = []
  const hook = {el: {dataset: {board: "3"}}, pushEvent: (_n, payload, reply) => { sent.push(payload); reply({pages: []}) }}
  await suggestPages(hook, {text: "Retr"}, {fresh: false})
  assert.deepEqual(sent, [{q: "Retr", board: "3", fresh: false}])
})

// PageLink as built, mounted with a pushEvent that answers as the server does.
let body
beforeEach(() => { ({body} = fakeDom()) })

const pages = [
  {code: "W-7", title: "Retry policy", path: "Design", insert: "[[Retry policy]]"},
  {code: "W-31", title: "Retention", path: "", insert: "[[W-31|Retention]]"},
]

function mountLink(value, reply = {pages}) {
  const sent = []
  const pushEvent = (name, payload, cb) => { sent.push({name, payload}); cb(reply) }
  return {...mountHook(PageLink, value, {dataset: {board: "3"}, extra: {pushEvent}, body}), sent}
}

const tick = () => new Promise(resolve => setImmediate(resolve))
const titles = menu => links(menu).map(a => a.children[0].children[0].textContent)

test("PageLink: its list is on <body>, marked and 320px wide", () => {
  const {menu} = mountLink("")
  assert.deepEqual(menu.dataset, {pageLinkMenu: ""})
  assert.equal(menu.style.width, "320px")
})

test("PageLink: typing [[ret asks the server and lists its reply", async () => {
  const {ta, menu, sent} = mountLink("")
  type(ta, "See [[ret")
  await tick()
  assert.deepEqual(sent, [{name: "page_link_suggest", payload: {q: "ret", board: "3", fresh: true}}])
  assert.deepEqual(titles(menu), ["Retry policy", "Retention"])
  assert.deepEqual(links(menu).map(a => a.children[1].textContent), ["W-7", "W-31"])
  assert.equal(active(menu), 0)
  assert.equal(menu.classList.contains("hidden"), false)
})

test("PageLink: the rest of a [[ word reuses the pages; a new [[ gathers them afresh", async () => {
  const {ta, sent} = mountLink("")
  type(ta, "See [[re")
  await tick()
  type(ta, "See [[ret")
  await tick()
  type(ta, "See [[ret]] and [[x")
  await tick()
  assert.deepEqual(sent.map(s => s.payload), [
    {q: "re", board: "3", fresh: true},
    {q: "ret", board: "3", fresh: false},
    {q: "x", board: "3", fresh: true},
  ])
})

test("PageLink: a single bracket asks nothing", async () => {
  const {ta, menu, sent} = mountLink("")
  type(ta, "See [ret")
  await tick()
  assert.deepEqual(sent, [])
  assert.equal(menu.classList.contains("hidden"), true)
})

test("PageLink: taking a row writes its insert over [[word, and tells the form", async () => {
  const {ta, el, menu} = mountLink("")
  type(ta, "See [[ret]] now", 9)
  await tick()
  el.fire("keydown", key("ArrowDown"))
  ta.sent.length = 0
  el.fire("keydown", key("Enter"))
  assert.equal(ta.value, "See [[W-31|Retention]] now")
  assert.equal(ta.selectionStart, 22)
  assert.deepEqual(ta.sent, ["input"])
  assert.equal(menu.classList.contains("hidden"), true)
})

test("PageLink: an empty reply lists nothing", async () => {
  const {ta, menu} = mountLink("", null)
  type(ta, "[[x")
  await tick()
  assert.equal(menu.children.length, 0)
  assert.equal(menu.classList.contains("hidden"), true)
})
