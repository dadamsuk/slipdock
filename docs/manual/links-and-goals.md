[Slipdock — the manual](../manual.md)

## Links and goals

The card modal's **Links** section searches cards on any board you can
open and links them as *relates to*, *contributes to* or *duplicates*.
Links are shown from both ends with the other card's board. A card that
others contribute to is a **goal**: it shows its contributions with a done
count, and the *Goal* swimlane axis and table column group cards by the
goal they contribute to. Blocking dependencies stay separate, since they
carry scheduling meaning.

### Web links

Separately, a card's **Web links** section holds references *out* of the
system: a page, a shared drive, a file somewhere else. Type an address and,
optionally, a label to show instead of it; a bare `example.com/spec` is taken
to be `https`, and `file://`, `smb://`, `ftp://` and `mailto:` are kept as
typed. Each link is datestamped with the day it was put there, and opens in a
new tab.

Attachments are files the board itself holds; web links point at things it
does not own. On the API they are `urls` on the card (`POST
/api/cards/:id/urls`, `DELETE /api/cards/:id/urls/:url_id`), and from the CLI
`slipdock weblink <id> <url> [--label TEXT]` and `slipdock unweblink <id> <url-id>`.

### Images on the card front

A card with an image attached shows it as a thumbnail across the top of its
front, under the cover strip — the first image attached, which counts the
screenshots pasted into its description and comments. Beside each image in
the card's **Attachments** there is a **Don't show on the card front** tick
box; tick it and the next image takes its place, or the card shows none.
Only PNG, JPEG, GIF and WebP images of 10 MB or less qualify: the front shows
the original file, and every reader of the board would download a larger one.

**Images**, in your [card views](card-views.md), turns thumbnails off. It is on
for comfortable cards and off for compact ones, where it shows a small square
in the row instead.

A list can keep images off its own cards: untick *Show images on the front
of this list's cards* in its settings (`slipdock set-column <board> <list>
--no-show-images`, or `show_images: false` on the list over the API). It is
on for a new list; off, that list's cards show no thumbnail whatever your
card views say, and the other lists are unchanged.

On the API, `hide_on_card` is on each attachment: `PATCH
/api/cards/:id/attachments/:attachment_id {"hide_on_card": true}` sets it, and
an upload can send it as a field. From the CLI, `slipdock card-front <id>
<attachment-id> --off` keeps an image off the front (without `--off`, lets it
back), and `slipdock attach <id> <file> --hide-on-card` uploads it kept off.

### Coloured edges

Apart from its cover colour, each of a card's four edges can wear its own
colour: a red top and a blue left, say, or all four the same to frame it.
Open the card and use **Borders**, under **Cover**: a row of swatches for
**Top**, **Right**, **Bottom** and **Left**, and an **All** row that sets the
four at once. The crossed-out circle takes an edge's colour off. The front
draws each coloured edge as a thin strip, inside the card so it keeps its
size, and the **Display** menu's **Cover colour** hides them with the cover strip.
They come with a card when it is duplicated, copied, exported and imported.

On the API they are `border_top`, `border_right`, `border_bottom` and
`border_left` on the card, each a palette colour name or null; send `""` to
take one off (`PATCH /api/cards/:id {"border_top": "red"}`). MCP's
`update_card` takes the same names, and `color` for the cover. The AI chat's
Edit mode sets them too (*give it a red frame and a teal cover*), and an
automation can with its `set_colours` action. From the CLI, `slipdock edit <id>
--border amber` colours all four, `--border-top red` (and `--border-right`,
`--border-bottom`, `--border-left`) one, which wins over `--border`, `none`
takes one off and `--no-border` takes them all off; `slipdock add` takes the
same, and `slipdock card` shows them as `Borders:`.

### Recordings

An audio file attached to a card (MP3, M4A, WAV, OGG, FLAC, WebM — anything
whose type is `audio/…`) plays in the card's **Attachments**, with a player
that can seek: the server answers the byte ranges a player asks for.

**Transcribe**, beside the player, sends the recording to the transcription
server an admin has set up under Configuration → Server → **Transcription
server**: a server of your own that speaks the small HTTP API below. Give its address (`https://host:8765`; `/v1` or
`/api/v1` on the end is fine too) and the auth token it issued; **Test
connection** asks the server for its status before anything is saved. The
token is kept on the server and never shown again — leave the box empty to
keep it, or tick **Forget the stored token**. With no address there is no
Transcribe button, and nobody but the people an admin has allowed
transcription (*Who may use transcription*, under [accounts and sharing](accounts-and-sharing.md)),
and admins, gets one: the API answers anybody else 403.

The work runs in the background, so the card can be closed meanwhile. The
transcript appears under the recording, folded away as **Transcript**; when the
server can tell voices apart it is written one speaker turn a line
(`Steve: …`). The transcript goes into [search](deep-search-and-ask.md), so what was said on
the call finds the card. If it fails the reason shows instead, and **Try again** sends it
again. Slipdock follows the server's client rules: it checks the server's API
version first, sends every recording with an idempotency key so a retry
never transcribes it twice, waits up to a minute for an answer before
following it as a job, and retries only what the server says is worth
retrying (a full queue, a model still loading, a timeout).

**Teaching it voices.** With **Teach it voices** ticked under the
transcription server (`slipdock admin set transcription_voiceprints=true`),
and a server that takes voiceprints (see below), putting a person's name on a
voice in a [meeting page's transcript](wiki.md#meeting-recordings-from-google-drive)
sends the longest stretch of
that person speaking to the server as a voiceprint under that name: their
lines one after another with nobody else between, the longest run of them,
kept clear of anybody else's line that overlaps it and half a second in from
each end, cut from the recording to at most a minute. If the server refuses
that clip (a `422`, such as "Multiple speakers"), the next-longest is sent,
up to three in all. Under three seconds is too
little and isn't sent, and nor is a placeholder like `Speaker 2`. It happens
in the background once the name is saved; the meeting page then says whether it
went and, if not, why. Naming
them again sends a fresh one. A recording that isn't WAV is cut with
`ffmpeg`, which the Docker image includes; on a server of your own, install it. It is off by default: it is that
person's voice going to your server, so tell the people you name.

#### What a transcription server must speak

Any server you run can do the transcribing, if it answers these over HTTPS,
with the token as `Authorization: Bearer <token>`:

- **`GET /v1/status`** → `200` with JSON `{"api_version": "1.x", "version":
  "…", "capabilities": [...]}`. Slipdock asks this before every recording and
  refuses a server whose `api_version` major isn't `1`. List `"diarization"`
  in `capabilities` if it can tell speakers apart.
- **`POST /v1/audio/transcriptions`**, multipart with `file` (the audio),
  `model=default` and `response_format` (`json`, or `diarized_json` when you
  listed diarization). Headers: `Idempotency-Key` (the same for every retry
  of one recording: answer a repeat with the same result rather than doing
  the work twice) and `Prefer: wait=60`. Answer either
  - `200` with `{"text": "…"}`, or for `diarized_json` with `{"segments":
    [{"speaker": "Steve", "text": "…"}, …]}`, or
  - `202` with `{"id": "<job>"}` (and optionally a `Location` header), when
    it will take longer than the wait.
- **`GET /v1/transcriptions/<job>`** → `200` with `{"status": "queued" |
  "running" | "completed" | "failed" | "cancelled"}`. A completed job
  carries the answer above as `result`, and a failed one `{"error":
  {"message": "…"}}`. Slipdock polls from 2 seconds, backing off to 30, for
  up to four hours.
- **Errors** as `{"error": {"code": "…", "message": "…"}}`. `429` and `503`
  are retried after `Retry-After`. Other `5xx` are retried with backoff, and
  `504` (with the job's `id` in the error, if there is one) means "still
  working: collect it later". `401`, `403`, `413`, `415` and `422` (`code`
  `audio_too_long` or `audio_undecodable`) are final and shown to the user.
- **Optional: `POST /v1/voiceprints`**, if you list `"voiceprints"` in
  `capabilities` (#1201): multipart with `file` (a mono 16 kHz WAV of one
  person speaking, 3 to 60 seconds) and `name` (who it is). Answer `200` or
  `201` with JSON (`{"id": "…"}` is enough). Keep it, replacing any earlier
  voiceprint under the same name, and from then on give that voice's turns
  that `speaker` name in `diarized_json`. Answer `422` for a clip that won't
  do (more than one voice in it, too little speech): Slipdock then offers the
  next-longest stretch, up to three. Other errors as above.

On the API, `POST /api/cards/:id/attachments/:attachment_id/transcribe` starts
it (202), and each attachment carries `transcript_status` (`running`, `done`,
`failed`), `transcript` and `transcript_error`. From the CLI, `slipdock
transcribe <id> <attachment-id> [--wait]`; an admin sets the server with
`slipdock admin set transcription_server_url=https://host:8765
transcription_server_token=…`.

### Reading text from files

Every PDF and image uploaded to a card, a wiki page or a wiki folder is read
for text in the background, so that search finds what is in it, including in
a scan or a photo of a page. There is nothing to turn on. Files uploaded
before this existed are worked through a few at a time.

It all happens on your server: `pdftotext` reads a PDF's text layer,
`tesseract` reads images and any PDF page that is only a picture, and nothing
is sent to an AI provider. The Docker image includes both, with English. Other
languages need their `tesseract-ocr-<lang>` package in the image and
`SLIPDOCK_OCR_LANGS` set, such as `eng+deu`. Installed by hand, without those
programs, uploads work as before and wait to be read until they are installed.

Files are read one at a time. A file is left out over 100 MB, and a document
stops at 500 pages, 100 scanned pages, a million characters or 30 minutes:
what was read by then is kept and the card says it is only the start. A PDF
page with a text layer is not also read as a picture, so words in a chart on
it aren't found.

On a card, the text is under the file, or the reason it couldn't be read with
**Try again**. Search needs the same setup as the rest of [semantic
search](deep-search-and-ask.md): an embedding model. A wiki file comes back as a
result of its own, for anyone who can read the board.

On the API, each attachment carries `text_status` (`queued`, `running`,
`done`, `failed`), `GET /api/attachments/:id/text` gives the words, and `POST
/api/cards/:id/attachments/:attachment_id/read-text` reads a card's file again
(202, or 409 while it is being read). From the CLI, `slipdock attachment-text
<attachment-id>` and `slipdock read-text <id> <attachment-id>`. Over MCP,
`download_file` with `text: true`. Search takes `kind: file`.

### Attachments over the API

A file goes up as the multipart form field `file` — the same upload the
card's drop zone takes, to a card or to a wiki page:

```sh
curl -s -H "authorization: Bearer $TOKEN" -F file=@shot.png \
     https://slipdock.example/api/cards/12/attachments
curl -s -H "authorization: Bearer $TOKEN" -F file=@diagram.png \
     https://slipdock.example/api/pages/W-31/attachments
```

Add `-F sha256=<hex>` (the file's SHA-256, as `sha256sum` prints it) and a
file that arrives different is a 422 `sha256_mismatch` with nothing stored;
`slipdock attach` sends it for every file.

The answer is the stored file — `id`, `filename`, `content_type`, `size`,
`sha256` (of the bytes as stored, so comparing it with `sha256sum` of your
copy verifies the upload without downloading it), `url` — and the `markdown` that shows it: `![shot.png](/attachments/5/shot.png)`
for an image, a plain link for anything else. Put that in a description, a
comment or a page body and the image appears inline, exactly as a pasted one
does. An optional `filename` field stores the file under another name; a
type the client leaves as `application/octet-stream` (curl's answer for
anything it does not know) is worked out from the name. `replace=true` (#1017)
deletes the card's or page's older files of the same name once the new one is
stored, and the answer lists their ids as `replaced`: a rebuild uploaded that
way leaves one current copy, and an upload that is refused leaves the old one
where it was.

`GET …/attachments` lists a card's or a page's files and
`DELETE …/attachments/:attachment_id` removes one, bytes and all. A card's
files are also in `attachments` on `GET /api/cards/:id`. The 250 MB limit and the
account's item and storage limits apply as they do in the browser: too large or
empty is a 422, a full account a 402.

**Behind a proxy, one request may be capped lower.** Cloudflare's free and pro
plans refuse a request body over 100 MB (business 200 MB) with a 413 that never
reaches Slipdock, and nginx's default `client_max_body_size` is 1 MB. In the
browser it makes no difference: the card sends a file over its websocket in
small chunks. Over the API and the CLI a file is one request, so upload
anything larger than the proxy allows through the browser, or raise the limit
(`client_max_body_size 260m;` for nginx). The CLI streams a file from disk, so
its size costs no memory.

From the CLI, a number is a card and anything else (`W-31`) a page:

```sh
slipdock attach 12 shot.png               # prints the Markdown that embeds it
slipdock attach W-31 /tmp/x.png --name diagram.png
slipdock attach 12 out/report.docx --replace   # and deletes the older report.docx files
slipdock attachments 12                   # ids, sizes and URLs
slipdock download 5                       # attachment #5's bytes, saved under its own name
slipdock download 5 --out - | less        # or --out F; --force overwrites a file already there
slipdock detach 12 5                      # attachment #5
```

---

← [Custom fields, scoring and votes](custom-fields-scoring-and-votes.md) · [Contents](../manual.md) · [Narrative](narrative.md) →
