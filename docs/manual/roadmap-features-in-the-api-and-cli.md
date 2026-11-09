[Slipdock — the manual](../manual.md)

## Roadmap features in the API and CLI

Boards carry `fields`, `milestones` and `votes` (the budget); columns carry
`category` and `horizon`; cards carry `date_precision`, `stated_health`,
`status_updates`, `fields` (stored values by key), `scores` (formula
results by key), `votes` and `links`. Set fields with
`PATCH /api/cards/:id {"fields": {"reach": 100, "size": "Large"}}`.
Endpoints: `/api/boards/:board/fields` (GET, POST; PATCH and DELETE with
`/:id`), `/api/boards/:board/presets/:key` (POST), `/api/boards/:board/milestones`
(GET, POST; DELETE with `/:id`), `/api/cards/:id/vote` (POST `count`),
`/api/cards/:id/status` (POST `health`, `body`), `/api/cards/:id/links`
(POST `to`, `kind`; DELETE with `/:link_id`), `/api/cards/:id/urls`
(POST `url`, `title`; DELETE with `/:url_id`).

CLI: `slipdock fields <board>`, `new-field`, `delete-field`, `preset <board>
rice|ice|value_effort`, `set <id> key=value…`, `vote <id> <n>`, `status <id>
on_track|at_risk|off_track [note]`, `link <id> <kind> <card-id>…`, `unlink`,
`weblink <id> <url> [--label TEXT]`, `unweblink <id> <url-id>…`,
`attach <id> <file>… [--name N]`, `attachments <id>`, `download <attachment-id> [--out F]`,
`detach <id> <attachment-id>…`,
`milestones <board>`, `milestone <board> <name> --date D`,
`delete-milestone`. Sorting accepts `votes` and `f:<field id>`.

---

← [Accounts and sharing](accounts-and-sharing.md) · [Contents](../manual.md) · [Running](running.md) →
