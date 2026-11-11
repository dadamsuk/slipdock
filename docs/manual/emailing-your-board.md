[Slipdock — the manual](../manual.md)

## Emailing your board

When the server receives mail (`SLIPDOCK_INBOUND_DOMAIN`, see
[Receiving email](../../README.md#receiving-email)), every person has their own
addresses to send cards and wiki pages in from their mail client: forward an
invoice, a bug report or a note to yourself, and it is a card; send meeting
notes or a day's journal to the page address, and it is a page.

**The addresses.** Each is yours alone, and only takes mail *from* your own
account's address (a board's card address also takes it from the board's
permitted senders, below):

| Address | Where it is | What mail to it makes |
|---|---|---|
| `card-…@<domain>` | the board's `…` menu › *Email to this board*; `slipdock inbound <board>`; `GET /api/boards/:board/inbound` | a card on that board's ready list, or a comment on card 42 when the subject starts `[#42]` |
| `page-…@<domain>` | the same places, next to the card address | a wiki page on that board, or a dated section added to one (`+ Title`) |
| `page-…@<domain>`, a folder's | the wiki tree: right-click a folder › *Email this folder…*; `slipdock inbound <board> --folder <path>`; `GET /api/boards/:board/inbound?folder=<path>` | a wiki page in that folder |
| `add-…@<domain>` | Account › *Email a card in*; `slipdock inbound me`; `GET /api/me/inbound` | a card through [Quick add](quick-add.md), to any board |

There is one card address and one page address per board you can write to
(somebody who can only read a board has neither), and one personal address.
The two board addresses are rotated together. Every one has a Copy button
and **New address**: that makes a new one, and mail to the old one bounces
from then on — do it if an address has leaked. `slipdock inbound <board>
--rotate` and `POST …/inbound/rotate` do the same. Taking back somebody's
share of a board turns their address for it off.

**Permitted senders.** A board's owner can let other addresses mail the
board's card addresses too: a colleague, a client, a monitoring service's
own address. List them in Board settings › Features › *Permitted senders*, one per
line (at most 50), or with `slipdock set-board <board> --inbound-senders
"ann@example.com,bob@example.com"` (`""` clears the list) or `PATCH
/api/boards/:board {"inbound_senders": [...]}`. The list belongs to the
board, so it covers everyone's card address for it. A permitted sender's mail still has to pass DMARC or DKIM. The card
(or, with `[#42]`, the comment) is added as the address's owner and opens
with *Sent by Ann <ann@example.com>*. It never answers a wait. The page
addresses, the folder addresses and Quick Add stay yours alone. *Email to
this board*, `slipdock inbound <board>` and `GET …/inbound` (`senders`)
list them.

**What the message becomes.**

- The **subject** is the title, with `Re:`, `Fwd:` and the like taken off
  (`(no subject)` when there is none).
- The **body** is the description, as Markdown: the text part, or the HTML
  converted when there is only HTML. Quoted replies and signatures are
  trimmed. A forward opens with a line saying who first sent it, and when.
- **Attachments** are uploaded to the card; images embedded in the message
  (`cid:`) are shown in the description where they were.
- The card is **yours**: its timeline says you added it, by email.

**Adding to a card that exists.** Start the subject with the card's number,
`[#42] Hinge replaced`, and the mail is a comment on card 42 instead of a new
card, as a [reply to a notification](#replying-to-a-notification) would be:
quoted history and your signature come off, attachments go on the card and
the comment links them, and a wait on you is answered. Only a leading
`[#42]` counts (after any `Re:` or `Fwd:`), so `Invoice #1234` is still a
title. The card has to be on that board or a sub-board beneath it; a card
anywhere else, archived, or a message with nothing to add bounces.

**Mail to the page address** makes a wiki page the same way: the subject is
the title, the body the page (its first line the summary), and attachments
are the page's files, with `cid:` images shown where they were. The page's
history says it came by email (`By email from <you>`).

- It goes in the **`Inbox`** folder, made the first time. Start the subject
  with a folder to file it there instead: `[Design/Decisions] Use Postgres`
  makes any folder along the path that is missing.
- **A folder's own address** files every page in that folder, without a
  `[Folder]` in the subject: right-click the folder in the wiki tree ›
  *Email this folder…* (or `slipdock inbound <board> --folder Minutes/2026`).
  `[Sub] Title` then files it in a folder beneath that one, and `+ Title`
  works as it does on the board's address. Each folder has its own address
  for each person who can write to the board, rotated on its own; deleting
  the folder turns its address off, and moving the folder to another board
  takes the address with it.
- A title another page already has is fine: you get a second page, as you
  would writing it in the wiki.
- **`+ Title` adds to a page instead** — a running log or a journal. `+
  Journal` finds the page called *Journal* on that board (any case) and adds
  `## 2026-10-24 — Your Name` with the message under it, in your own
  timezone; its attachments go on the page. The whole body goes in, however
  long. With several pages of that title, the one changed most lately gets
  it; archived pages and templates are never added to.

**The personal address reads the subject as Quick Add does**: `Renew the cert
due: friday #high @dan`, `#todo` for a list, `every:`, `snooze:`, `title;
description;; comment` (after one `;` the card's description, after two a
comment on it), and the model when it is on. The mail's body is the
description too: a subject's `; description` goes ahead of it, and stands
alone when the mail has no body. With no board named the card goes to
your Quick Add default (Account › *Preferences*). Name one with `[Board] Title`
— by name or code, the way a mail filter writes it — or in words the model
reads ("… on the website board").

**Why a message bounces.** The bounce says which of these it was:

- it didn't come from your account's address, or couldn't be shown to (it
  passed neither DMARC nor DKIM);
- the address is unknown, or has been replaced with a new one;
- you can no longer write to that board, or it is archived;
- the board named in the subject (`[Board]`) isn't one you can reach — the
  bounce lists the ones you can;
- the account that owns the board is full (`card_limit_reached`) or its trial
  has run out. Attachments that don't fit the storage limit are left off and
  a comment on the card (or a note at the end of the page) names them; only
  a message that is nothing *but* files that don't fit bounces;
- for `+ Title`: there is no page of that title on the board (the bounce
  suggests up to five close titles), nothing follows the `+`, or the message
  had nothing in it to add;
- too much mail to one address or from one sender in an hour.

Automatic mail — auto-replies, bulk and list mail, anything that says
`Auto-Submitted` — is ignored rather than bounced, so two systems can't
answer each other forever.

**Did it arrive?** Account › *Email log* (`/account/email-log`; also `slipdock inbound log` and
`GET /api/inbound/log`) lists your last 50 messages: what each made, or why it
bounced or was ignored.

**A link back.** Tick *Email me back a link to each card my mail makes* on the
Account tab (`slipdock inbound me --ack on`, `POST /api/me/inbound
{"ack": true}`) for one short reply per message with the new card's link.
It is never sent for mail that bounced or was ignored, and never twice for one
message.

### Replying to a notification

Emails about a card can be answered from your mail client. Mentions, a wait
on you, and an automation's email about a card each come with a `Reply-To:
reply-…@<domain>` address made for you and that card alone. Reply as you
would to anyone, from Gmail, Outlook, Apple Mail or your phone, and what you
wrote is a comment on the card, by you:

- **Quoted history is taken off**: the `On … wrote:` line and everything
  under it, `>` lines, Outlook's `From:/Sent:` block, your signature (from
  `-- `) and "Sent from my iPhone". What is left is the comment.
- **Attachments** go to the card, and the comment links to each one.
- **`@name`** in a reply tells that person, as a comment typed on the card
  does.
- Emails about one card **thread together** in your mail client, and each
  says at the bottom that it can be replied to.

**Answering a wait by reply.** When a card waits on you, you get an email
saying what it needs, with any questions and choices numbered. Your reply
answers it, as `slipdock answer` would:

- With choices, start with the choice's number (`2`) or its text (`EU`) to
  pick it. Anything on the lines after is your answer in words. A reply that
  doesn't start with a choice is a free-text answer.
- With several questions, answer each in a paragraph of its own, in order.
  Questions left over stay unanswered.
- A reply that can't be matched, such as more paragraphs than there are
  questions, is added as a comment instead. The wait stays open, and a
  second comment says why.

While the wait is open, a reply of yours to any email about that card answers it, not only a reply to the wait email.

**Why a reply bounces.** The bounce says which:

- it was empty once the quoted message was taken off, and had no files;
- it came from a different address than the one the email went to, or
  passed neither DMARC nor DKIM;
- the reply address is more than a year old (comment on the card instead),
  or isn't one this server made;
- the card has since been deleted or archived, or you can no longer comment
  on it.

An address stops working if the server's inbound secret is rotated, once
the previous secret is dropped.

The code: `Slipdock.Inbound.Tokens` (addresses), `Slipdock.Inbound.Cards`,
`Slipdock.Inbound.Pages` and `Slipdock.Inbound.QuickAdd` (what mail makes), `Slipdock.Inbound.Ack`,
`Slipdock.Inbound.ReplyToken` and `Slipdock.Inbound.Replies` (replies),
`Slipdock.Inbound.WaitReply` (answering a wait). The
design and the Cloudflare runbook are W-1933 on the Slipdock board's wiki.

---

← [Quick add](quick-add.md) · [Contents](../manual.md) · [Deep search and Ask](deep-search-and-ask.md) →
