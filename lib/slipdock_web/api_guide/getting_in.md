
## Getting in

This guide is long. `GET <%= @base %>/api/guide?section=short` is the part
needed to work a board, ending with the names of the rest, and
`?section=<name>` is one of those (`all`, or no `section`, the whole
guide; an unknown name is a `404` listing them).

Every endpoint but this one needs an API token:

    curl -s -H "Authorization: Bearer $SLIPDOCK_TOKEN" <%= @base %>/api/me

<%= @who %>

**If you have no token, ask for one — you do not need access to this
server.** `slipdock auth` does the whole thing; by hand it is two calls:

    curl -s -X POST <%= @base %>/api/auth/device \
      -H 'content-type: application/json' \
      -d '{"label": "what you are", "scope": "write"}'

`scope` is `read` or `write`. Asking for `admin` this way is refused with
`invalid_scope`: an admin token is made by an admin on the account page.

That answers with a `user_code` and a `verification_uri`. Show both to the
person and ask them to approve it in a browser. Then poll, no faster than
the `interval` it gave you:

    curl -s -X POST <%= @base %>/api/auth/device/token \
      -H 'content-type: application/json' \
      -d '{"device_code": "..."}'

`authorization_pending` means keep waiting; `slow_down` means you are
polling too fast and should wait longer, not retry harder; `access_denied`
means they said no; `expired_token` means start again. Success hands back a
`token`. The code lasts ten minutes and works once.

**Save what you are given**, so the next session does not have to ask the
person again: the token in `~/.config/slipdock/token` (mode 600), and this
server's address in `~/.config/slipdock/url`. Both files are where the CLI
and the skills look. `$SLIPDOCK_TOKEN` and `$SLIPDOCK_URL` override them.
The CLI also keeps one token per server under `~/.config/slipdock/tokens/`
and sends each only to the server that issued it; `slipdock auth` writes
both. Never send a token to an address other than the one it came from.

If you have none of the skills installed and would like them —
the wiki, documents, working a backlog unattended — one line fetches them
into `~/.claude/skills` and needs nothing but `curl` and `tar`:

    curl -fsSL <%= @base %>/install.sh | sh

On Windows, in PowerShell (into `%USERPROFILE%\.claude\skills`, which
WSL's `install.sh` would miss):

    irm <%= @base %>/install.ps1 | iex

That is the skills. The `slipdock` CLI is `/cli/install.sh` (Linux,
macOS; it needs Erlang/OTP 27+ and says how to get it) or, on Windows,
`/cli/install.ps1` (Erlang and all):

    curl -fsSL <%= @base %>/cli/install.sh | sh
    irm <%= @base %>/cli/install.ps1 | iex

`401` means no token or a dead one — ask for a new one rather than guessing.
`403` means the token is good but that board or card is not yours to
change; say so rather than working around it. A board you cannot read at
all is a `404`, the same as one that does not exist — and a board's name or
code only ever means one of yours (or one shared with you), never somebody
else's that happens to be called the same. Two `403`s name the **token**
instead, and mean it is deliberately limited rather than anything being
broken — report them, do not retry:

- `this API token is read-only` — granted read access only.
- `this API token's scope doesn't allow it` — confined to certain boards.

**Comment access** (#863) sits between read and write: a board, card,
page or folder can be shared at `comment`. A commenter reads, and may
comment (`POST …/comments`), report a status (`POST …/status`), vote with
a comment, and delete their own comments — nothing else. Every change to
the card or page itself (fields, list, checklist, links, attachments,
dependencies, sub-board, archive, delete) is a `403 you don't edit this
card`; a reader commenting gets `403 you don't comment on this card`.

`402` is a limit, and always carries `"retryable": false` because it is not
a fault in your request: fixing the title and trying again will fail
identically, forever. Tell the person and stop. `GET /api/me` says where
they stand before you start — `cards` for the item count, `limits` for all
of it.

- `card_limit_reached` — the board's owner has used up the **items** their
  account allows. A card, a wiki page and an uploaded file each count as
  one, so writing it up as a page instead will not get round it. Suggest
  archiving something finished with.
- `board_limit_reached` — they own as many boards as this server allows one
  person. Sub-boards, the ones behind subcards, do not count.
- `storage_limit_reached` — their uploaded files fill the space allowed.
  Only deleting attachments frees it; archiving the card does not.
- `trial_expired` — a free trial has run out. Nothing new can be added
  anywhere on their boards; everything already there stays editable. They
  have to subscribe.

Not only creating meets these. Restoring something archived asks for it
back into the count; moving a card onto a board somebody else owns counts
it, its subcards, their pages and their files against *that* owner; an
import counts its archived rows too; and `POST /api/boards/welcome` needs
room for the whole tour.

Reads are `GET`, writes are `POST` or `PATCH`, and bodies are JSON with
`Content-Type: application/json`. Boards, lists, tags, templates and saved
views can be addressed by name as well as by id — `/api/boards/3` and
`/api/boards/Roadmap` both work, case-insensitively — but names are
ambiguous and get renamed, so use the id once a response has told you one.
A board also has a `code`: a short, unique handle of its own (“QVM V1
Remediation” is `qvm-v1-rem`) that addresses it too — `/api/boards/qvm-v1-rem`.
It is generated from the name and can be edited, so it is stabler than a
name but still not the id.
Every write appears instantly in anyone's open browser and is recorded in
the board's activity log, so there is no need to announce changes twice.

A `slipdock` CLI wraps all of this (`slipdock --help`) if the machine you are on
has it. The API is the contract; the CLI is a convenience.

### Over MCP

A client that speaks the Model Context Protocol can use this server as an
MCP server at `<%= @base %>/mcp`: stateless Streamable HTTP, authenticated with
the same bearer token as the API, or by signing in through the browser
(OAuth 2.1 with dynamic client registration and PKCE — the way claude.ai
and the Claude apps connect; discovery starts from the `401` that `/mcp`
answers without a token). It offers a small set of tools rather
than the whole API: `whoami`, `get_guide` (this text, short; `section` for the
rest), `list_boards`,
`get_board`, `list_cards` (`full: true`: every card as `get_card`
gives it, so a whole board reads in one call), `get_card`, `search`, `ask` (a
model call, so slower), `read_page`, `list_pages`, `page_info`, `page_history`, `activity` (a
board's log, or one card's), `download_file` (a file, by
attachment id; `link: true`, a URL to curl), `list_automations`, and for
writing `create_card`, `update_card` (fields, flags, tags, assignees,
dependencies, the checklist, recurrence, snooze), `move_card` (to another board too),
`comment`, `leave_handoff`, `upload_file` (onto a card or page;
a shell: `link: true`), `complete_card`, `status_update` (a card's stated health, with
a note: the progress report on an epic),
`archive_card` (and restore), `delete_card`,
`create_list`, `create_tag`, `delete_list`, `create_board`, `archive_board` (and
restore), `delete_board`, `write_page`, `update_page` (a page's
title, summary, parent, position and folder, archiving and restoring it,
and pinning it to a card) and `revert_page` (a page
back to a revision, as a new one, against `base_hash`),
`manage_automation` (owner only), `list_tools`, `install_tool`, `garden` and
`garden_decide` (tidy-up suggestions), and `claim_job`,
`job_progress` and `finish_job` to take runner jobs from a board's
queue (see "Runners" below), and `release_now` (Release now on a board
with batched releases; `check: true` only reads). Archiving can be undone; the
deletes can't, so `delete_card`
needs `confirm: true`, `delete_board` needs `confirm` set to the board's
code, and `delete_list` refuses a list holding cards unless
`with_cards: true`. A read-only
token, or a connection the person approved read-only, can call the read
tools, and a write tool answers it with an error saying so. The conventions in this guide apply the same way through
either door. Prompts: `plan-my-day`, `weekly-review`, `triage`, `resume`,
`leave-handoff`, `tidy-board`. Resources, which the
person attaches: `slipdock://card/42`, `board/`, `page/`, `view/`, `work`.

### The AI key, and which model answers

Anything that asks a language model — the written answer from
`POST /api/ask`, writing an automation rule in English, the chat and edit
panels, the narrative — runs on the **account holder's own** key or
endpoint, kept on the server, never shared.

**Search is the exception.** `GET /api/search` (the MCP `search` tool,
`slipdock search`), the index behind it and scheduled automations run on
the **server's** AI: one admin's settings, chosen by an admin under
Configuration → AI for search and automations. An index is searched with
the model that built it, so it can't be yours. Your own key,
endpoint and `embed_model` change nothing about search (`embed_model` is
read only for the admin chosen there), and `/api/ask` needs both: the
server's AI to find the cards, yours to write the answer. A search that
answers `Semantic search isn't set up on this server` is for an admin to
fix — tell the user that, and do not retry or ask them for a key.

`GET /api/me` says what yours is:

    "ai_key": {"configured": true, "masked": "sk-or-v1…10d8",
               "set_at": "2026-10-01T15:56:49Z", "ai_available": true},
    "ai": {"base_url": "https://openrouter.ai/api/v1", "own_endpoint": null,
           "model": "google/gemini-2.5-flash-lite", "own_model": null,
           "embed_model": null, "fallback_models": []}

`configured: false` with `ai_available: false` means those endpoints will
answer `AI features need a model to talk to` and nothing you do to the
request will change it — say so rather than retrying.

There are two ways to give them one:

* **A key**, for the server's endpoint (OpenRouter by default):
  `PUT /api/me/ai-key {"api_key": "sk-or-…"}` (`slipdock ai-key <key>`),
  removed with `DELETE /api/me/ai-key`. Billed to its owner's OpenRouter
  account, so never put somebody else's key on your account, and never
  read a key back out of a file and quote it anywhere.
* **An endpoint of your own** — any OpenAI-compatible chat completions API,
  typically a model server on the same network, which usually wants no key
  at all and sends nothing off it:

      PUT /api/me/ai-provider {"base_url": "http://llm.local:1234/v1",
                               "model": "qwen/qwen3.5-9b"}

  (`slipdock ai-endpoint <url>`, then `slipdock ai-model <id>`.) Only the
  fields you send change; `""` clears one, so `{"base_url": ""}` goes back
  to the server's default. `GET /api/me/ai-models` (`slipdock ai-models`)
  lists what that endpoint can run, which is where a `model` id comes
  from — an id from OpenRouter means nothing to a local server, and the
  other way round. Both are also in the web UI under
  **Account → AI model**.
