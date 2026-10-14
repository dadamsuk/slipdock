// node --test assets/js — the parts of the transcript player that are not the DOM.
import {test} from "node:test"
import assert from "node:assert/strict"
import {clock, currentTurn, nextSpeed, matches, problemMessage, keyAction, typing, SPEEDS} from "./transcript_player.js"

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
  assert.equal(problemMessage("no_folder"), "This vault has no recordings folder set — Vault settings.")
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
