[Slipdock — the manual](../manual.md)

## Receiving email

Slipdock doesn't run a mail server. Cloudflare Email Routing receives mail
for a domain you own and an Email Worker (`cloudflare/inbound-email/`) posts
each message to `/api/inbound/email`, signed. Both of these are read on every
boot, and with either unset the feature is off and its endpoint answers 404:

```sh
SLIPDOCK_INBOUND_DOMAIN=in.example.com     # the domain mail is received on
SLIPDOCK_INBOUND_SECRET=…                  # shared with the Worker (wrangler secret put)
SLIPDOCK_INBOUND_SECRET_PREVIOUS=…         # still accepted while you rotate it
```

Once it is on, everybody has a `card-…@` and a `page-…@` address (a new card,
a new wiki page or `+ Title` to add to one; `[#42] …` to the card address
comments on card 42) for each board they can
write to (the board's `…` menu › *Email to this board*, `slipdock inbound
<board>`), a `page-…@` address of its own for any wiki folder (the tree's
*Email this folder…*, `slipdock inbound <board> --folder <path>`) and a personal `add-…@` address that goes through Quick Add
(Account, `slipdock inbound me`): see [Emailing your
board](emailing-your-board.md) for what a message becomes and why
one might bounce. A board's automations can act on what mail brings in, as
it arrives: the `card_emailed` and `page_emailed` triggers (flag it for
review, tag it, alert someone; [Rules for what mail brings
in](automations-and-alerts.md#rules-for-what-mail-brings-in)). Emails about a card (mentions, waits, automation emails)
carry a signed `reply-…@` `Reply-To`, so a reply becomes a comment on the
card or answers the wait ([Replying to a
notification](emailing-your-board.md#replying-to-a-notification)); rotating the
secret retires those addresses once the previous one is dropped. Each person's last 50 inbound messages, and what came of
each (what it made, or why it bounced or was ignored), are on the account's
*Email Log* tab, at `GET /api/inbound/log` and with `slipdock inbound log`. The design
and the deploy runbook are on the Slipdock board's wiki (W-1933).

---

← [Running it for other people](running-it-for-other-people.md) · [Contents](../manual.md) · [Google Drive, for meeting recordings](google-drive-for-meeting-recordings.md) →
