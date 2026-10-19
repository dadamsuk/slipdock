// node --test assets/js — the parts of the transcript player that are not the DOM.
import {test} from "node:test"
import assert from "node:assert/strict"
import {clock, currentTurn, nextSpeed, matches, problemMessage, problemLink, keyAction, typing, speakerRename, SPEEDS} from "./transcript_player.js"

test("times read as minutes and seconds, and hours when they need them", () => {
  assert.equal(clock(65_000), "1:05")
  assert.equal(clock(3_725_400), "1:02:05")
  assert.equal(clock(-1), "0:00")
  assert.equal(clock(undefined), "0:00")
})

test("the turn being spoken is the last to have started", () => {
  const starts = [1_500, 4_000, 65_000]
  assert.equal(currentTurn(starts, 0), -1)
  assert.equal(currentTurn(starts, 1_500), 0)
  assert.equal(currentTurn(starts, 3_999), 0)
  assert.equal(currentTurn(starts, 4_000), 1)
  assert.equal(currentTurn(starts, 999_999), 2)
  assert.equal(currentTurn([], 10), -1)
})

test("speed steps up and down through the list and stops at either end", () => {
  assert.deepEqual(SPEEDS, [0.75, 1, 1.25, 1.5, 2])
  assert.equal(nextSpeed(1, 1), 1.25)
  assert.equal(nextSpeed(1, -1), 0.75)
  assert.equal(nextSpeed(0.75, -1), 0.75)
  assert.equal(nextSpeed(2, 1), 2)
  // A rate set some other way starts from 1×.
  assert.equal(nextSpeed(1.1, 1), 1.25)
})

test("search finds the turns that hold the words, whatever their case or spacing", () => {
  const turns = ["Alice  Hello there", "Bob Shall we START?", "Alice hello again"]
  assert.deepEqual(matches(turns, "hello"), [0, 2])
  assert.deepEqual(matches(turns, "shall   we"), [1])
  assert.deepEqual(matches(turns, "nobody"), [])
  assert.deepEqual(matches(turns, "  "), [])
})

test("a refusal from the server reads as words", () => {
  assert.equal(problemMessage("not_connected"), "Google Drive isn't connected for this vault.")
  assert.equal(problemMessage("not_found"), "Recording not found on Drive.")
  assert.equal(problemMessage("revoked"), "Drive access was revoked — reconnect on your account page.")
  assert.equal(problemMessage("no_folder"), "This vault has no recordings folder set.")
  assert.equal(problemMessage(null), "The recording couldn't be played.")
})

test("no recordings folder: a link for the owner, a name to ask for anybody else", () => {
  const owner = {settingsUrl: "/vaults#recordings-folder-7"}
  assert.equal(problemMessage("no_folder", owner), "This vault has no recordings folder set —")
  assert.deepEqual(problemLink("no_folder", owner), {href: "/vaults#recordings-folder-7", label: "Vault settings"})

  const reader = {owner: "David <&>"}
  assert.equal(problemMessage("no_folder", reader), "Ask David <&> to set this vault's recordings folder.")
  assert.equal(problemLink("no_folder", reader), null)
  assert.equal(problemLink("no_folder"), null)
})

test("a page in no vault says so, with no settings link", () => {
  const help = {settingsUrl: "/vaults#recordings-folder-7"}
  assert.match(problemMessage("no_vault", help), /^This page isn't in a vault, so its recording can't be played\./)
  assert.equal(problemLink("no_vault", help), null)
  assert.equal(problemLink("not_found", help), null)
  assert.equal(problemMessage(null), "The recording couldn't be played.")
})

test("keys act on the player, but not while typing or with a modifier", () => {
  const body = {tagName: "BODY"}
  assert.equal(keyAction({key: " ", target: body}), "toggle")
  assert.equal(keyAction({key: "ArrowLeft", target: body}), "back")
  assert.equal(keyAction({key: "ArrowRight", target: body}), "forward")
  assert.equal(keyAction({key: "[", target: body}), "slower")
  assert.equal(keyAction({key: "]", target: body}), "faster")
  assert.equal(keyAction({key: "x", target: body}), null)
  assert.equal(keyAction({key: " ", target: {tagName: "INPUT"}}), null)
  assert.equal(keyAction({key: " ", target: {tagName: "DIV", isContentEditable: true}}), null)
  assert.equal(keyAction({key: "ArrowLeft", metaKey: true, target: body}), null)
  assert.equal(typing(null), false)
  assert.equal(typing({tagName: "TEXTAREA"}), true)
})

test("naming a voice asks for a change only when there is one", () => {
  assert.deepEqual(speakerRename("Speaker 1", "  Priya Shah "), {from: "Speaker 1", to: "Priya Shah"})
  assert.equal(speakerRename("Speaker 1", "Speaker 1 "), null)
  assert.equal(speakerRename("Speaker 1", "   "), null)
  assert.equal(speakerRename("", "Priya"), null)
  assert.equal(speakerRename("Speaker 1", undefined), null)
})
