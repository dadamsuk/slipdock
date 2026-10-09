---
name: slipdock-capture
description: Turn a meeting into decisions, actions and card changes on the user's self-hosted Slipdock board with the `slipdock` CLI — send a recording or transcript, settle the questions with the user, preview and commit. Use when the user has a meeting recording, a transcript (WebVTT, SRT, a Fireflies or Otter export, "Name: words" notes) or meeting notes and wants what was decided and agreed on their board, or asks what a captured meeting found. Only where the server's admin has turned meeting mode on.
---

# Meeting capture

Slipdock reads a meeting alongside the board's cards and wiki and proposes
what it produced: **decisions** (written to the meeting's own wiki page,
*Decisions / <meeting> · <date>*, grouped by topic),
**actions** (new cards), **changes to existing cards**, **open questions** and
**ideas**. Every proposal quotes the transcript word for word, and anything
uncertain becomes a question for a person. **Nothing reaches the board until
somebody commits the capture**, in one write that can be undone as a whole.

Your job is to get the meeting in, put the questions to the user, and commit
when they say so. The integrity of the result depends on two rules:

1. **Answer a question only with the user's own answer**, given to you in the
   conversation. Never answer one from your own reading of the transcript —
   if you think you know, say what you think and ask them. Answers are
   recorded as theirs.
2. **Commit only when the user asks you to**, and with the preview digest of
   what you showed them, so exactly that is written.

## First: is it on?

```sh
slipdock meetings          # "Meeting mode: on", or "meeting mode is off on this server"
```

Off means none of this exists on that server. Say so; an admin turns it on
(Configuration → Meetings). Don't work around it by writing cards yourself
from the transcript — that skips the checks this exists for.

## Send the meeting

```sh
slipdock capture new <board> --transcript meeting.vtt --title "Pricing sync" \
  --when 2026-10-07T10:00 --attendees "Priya, sam@example.com"
slipdock capture new <board> --audio call.m4a --transcript call.vtt   # recording and transcript
cat notes.txt | slipdock capture new <board> --transcript -           # "Name: words" lines on stdin
```

- Transcripts: WebVTT, SRT, plain `Name: words` lines (optionally with
  `[00:01:02]` stamps), Fireflies or Otter exports (text or JSON). Text is kept
  exactly as sent: it is the evidence.
- `--ics invite.ics` gives attendees, start and title; attendees are the
  strongest hint at who is speaking, so give them when you can.
- `--findings mine.json` adds your own reading of the meeting, in the format
  `slipdock capture schema` prints. They are checked exactly like Slipdock's:
  a quote that is not in the transcript is dropped.
- Sending the same transcript to the same board again finds the first capture
  rather than making a second.

It answers with the capture's id and link. Reading takes a little while
(the pipeline reads the meeting twice and checks every quote); the person who
sent it is emailed when it is ready.

## Settle the questions, with the user

```sh
slipdock capture show <id>       # findings, what each becomes, the questions with numbered answers
```

Put each open question to the user in plain words, with its answers, and
wait. Then record **their** answer:

```sh
slipdock capture resolve <id> <question-id> <answer>      # the answer's number or its label
slipdock capture resolve <id> <question-id> 2 --replayed 7:38-7:44   # if they listened again first
slipdock capture leave-out <id> <finding-id>              # they don't want that one
slipdock capture include <id> <finding-id>
```

"Not decided" and "Nobody yet" are always answers; they are good ones when
the meeting really didn't settle something. Questions you might see: *which
reading* (the two readings disagree — 15% or 50%?), *who is meant* (a name
nobody on the board has), *existing card or new*, *who said it*.

## Preview, then commit when asked

```sh
slipdock capture preview <id>              # exactly what will be written, and a digest
slipdock capture commit <id> --preview <digest>
```

Show the user the preview. Commit only when they say to. A commit is refused —
and writes nothing — if a card it changes was edited since the review read it
(it names the card); read the capture again and re-preview. A committed
capture is never written twice.

```sh
slipdock capture undo <id>          # undo it all; refused, listing them, if something was edited since
slipdock capture undo <id> --rest   # undo everything but what was edited since
slipdock capture discard <id>       # decide against it: nothing is written, the record stays
slipdock capture retry <id>         # a capture that failed (the reason is in `show`)
slipdock capture ls <board>
```

Every command takes `--json`. Cards and decisions that came from a meeting
carry a *From a meeting* block with the quote, the speaker and who committed
it, and searching for words said in the meeting finds them.

## Without the CLI

The same, over HTTP (`Authorization: Bearer $SLIPDOCK_TOKEN`; the endpoints
are in `slipdock guide`, section *Meeting capture*, when it is on):

```sh
curl -s -H "Authorization: Bearer $SLIPDOCK_TOKEN" -F transcript=@meeting.vtt -F title="Pricing sync" \
  "$B/api/boards/<board>/captures"
curl -s -H "Authorization: Bearer $SLIPDOCK_TOKEN" "$B/api/captures/<id>"
curl -s -H "Authorization: Bearer $SLIPDOCK_TOKEN" -H 'content-type: application/json' \
  -d '{"question": 9, "answer": "1"}' "$B/api/captures/<id>/resolve"
```

Over MCP: `capture_meeting`, `get_capture`, `resolve_capture_question`,
`commit_capture` — with the same two rules.

## Voiceprints are not yours to make

If the server has voiceprints on (`slipdock meetings` says so), a person can
enrol their own voice to help attribute who spoke. That is consent to
biometric data, so it is theirs to give: point them at Account › Voiceprint,
or at `slipdock voiceprint enrol --audio me.wav --consent` to run themselves.
Never enrol, or delete, a voiceprint on the user's behalf.
