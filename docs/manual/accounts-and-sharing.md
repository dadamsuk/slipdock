[Slipdock — the manual](../manual.md)

## Accounts and sharing

Every page needs a signed-in user. The login page asks for an email address and
sends a one-time link **and a six-digit code**, either of which works, once,
within 15 minutes; using one signs you in for 30 days on that browser. The code
exists for the times the link cannot be clicked — read out of a log, typed from
a phone.

**Passkeys.** Once signed in, add a passkey under **Account → Sign-in & passkeys** (or, when
finishing an email sign-in, press **Sign in and set up a passkey** under the
**Sign in** button to land straight there): name
it, press **Add a passkey**, and unlock the device the browser asks for (a
fingerprint, a face, a PIN, a security key). From then on the login page has a
**Sign in with a passkey** button that needs no email: the device offers the
accounts it holds for this server and signing in takes a touch. The email link
and code keep working; a passkey is another way in, not a replacement.

- A passkey belongs to the address the browser was on when it was made. One
  made at `https://slipdock.example.com` does not work at a tailnet IP, and
  browsers only offer passkeys over https (or on `localhost`).
- The device has to verify you (not just be present), so a passkey stands in
  for the email *and* the code.
- Up to 20 per account. Each lists when it was added and last used; **Remove**
  stops it signing in at once. A lost phone can also be removed from a
  terminal: `slipdock passkeys`, then `slipdock passkeys remove <id>`, or
  `GET` / `DELETE /api/me/passkeys[/:id]`.
- A disabled account cannot sign in with a passkey either. A security key
  whose signature counter goes backwards (a copied key) is refused.

Every board has an owner, fixed when it is made: the board settings form and
`PATCH /api/boards/:board` cannot change it, and a board somehow left with no
owner is open to nobody rather than to everybody. Ownership moves only when an
account is deleted and its boards are handed over.

**Your own pages**, under the avatar menu's **Account & settings**: one page
per section, listed in a side nav on the left (on a phone, a picker at the top
that opens onto the same list), because one long scroll had the display name,
the AI key and a board importer on it and nothing told you which was which.
The current section is marked in the nav and named again over its content:

- **Profile** (`/account`) — your display name and timezone, how many cards you
  have used against the limit if there is one, every time an admin has been let
  into your boards and why, your personal address for [emailing
  cards in](emailing-your-board.md), and the licence.
- **Preferences** (`/account/settings`) — the dials: where quick add puts a card,
  whether the line is read by a model, your AI model, what is on show, header
  links and Google Drive.
- **Sign-in & passkeys** (`/account/sign-in`) — your passkeys, and signing out.
- **API tokens** (`/account/tokens`) — make, inspect and revoke the tokens the
  CLI and agents sign in with.
- **Set up an agent** (`/account/agent`) — pointing Claude, ChatGPT or another
  agent at this server.
- **Machines** (`/account/machines`) — the computers enrolled to run the
  runner daemon for you: each one's system, fingerprint, boards and when it
  was last seen, revoking one (its key stops working at once), and a
  one-time enrolment key for `slipdock-runner init --key` on a machine with
  nobody at its screen. A machine's code from `slipdock-runner init` is
  approved at `/account/machines/approve`, which shows its hostname, system
  and fingerprint and asks which boards it may serve. Each machine opens
  its own page, where its runners are added, changed, paused and removed
  ([Machines](machines.md#the-machines-page)); machines of other people that
  serve a board you're on are listed too, to see. Also `slipdock
  machines`.
- **Import & export** (`/account/data`) — everything you have as a zip, and
  boards as files another Slipdock can read back.
- **Email log** (`/account/email-log`, only while the server receives mail)
  — your last 50 messages to its inbound addresses, and what each one made
  or why it bounced or was ignored; also `slipdock inbound log`.

**Setting the server up.** A server nobody has claimed shows a setup wizard and
sends every other page to it. It asks who may register, how mail goes out and
who the admin is, and it wants a token printed in the log on first boot — so
that finding the page first is not enough to claim somebody else's instance.
Finishing it closes the page for good. `SLIPDOCK_ADMIN_EMAIL`, or
`mix slipdock.setup --admin you@example.com`, does the same thing without a
browser.

**Who may get an account** is then one of four modes, under **Admin**:

- **Nobody can register** (the default) — accounts exist only because you made
  them by sharing something.
- **Only addresses I list** — an allowlist of addresses and of domains. A bare
  domain lets anybody there in, which is how you admit a team.
- **I approve each request** — people ask on the sign-in page and you say yes or
  no. Needs a working mail server, and Slipdock refuses the mode without one,
  because otherwise nobody is ever told that somebody is waiting.
- **Anyone can register** — only sensible when the server is already behind a
  boundary of your own (Tailscale, a VPN, an authenticating proxy).

Changing the mode never removes anybody: people who already have an account keep
it.

**Running it for other people.** A few more settings make a shared server
defensible. An **item limit** caps how much one person's own boards may hold —
a card, a wiki page and an uploaded file each count as one item, so writing the
work up as pages is not a way round it; things on boards shared *with* them cost
them nothing, and archiving a card or a page frees one up. A **free trial** can
be switched on: free accounts stop being able to add anything so many days after
they were made, which is independent of the item limit, so an account can have
no item limit at all and still run out of trial. Neither deletes anything or
locks anybody out — what ends is adding. **Who people can see** can be narrowed
from everyone on the server to only the people somebody actually shares a board,
card or page with, which also keeps other customers' addresses out of anything
sent to a language model. And **whether sharing with a stranger makes them an
account** can be turned off, so you can only share with people who already have
one.

**The ceilings.** Separately, every install has three of them on, however it is
run: 1,000 boards one person may own, 250,000 items on those boards, and 10 GB of
uploaded files. They are a safety rail rather than a price list — a runaway
script should hit something — so **admins are not exempt either**, and an admin
who means to go past one raises it. Each has its own switch, so any of them can
be turned off without losing the number behind it. Where a free account's own
allowance is lower than a ceiling, the lower one wins.

**Who has paid.** There is no billing in Slipdock. What takes somebody off the
free allowance and off the trial clock is a **paid-up date**, set per person
under Users (or `slipdock admin paid <email> <date>`) by whoever took the money.
An account with no date in the future is a free one — unless an admin has marked
it **unlimited** (Users → tick *Unlimited*, or `slipdock admin unlimited <email> on`),
which does the same for a named person with no date to invent: no free allowance,
no trial. The ceilings above still apply to them, as they do to admins.

**Who may use transcription.** Transcribing a card's recording and teaching the transcription server voices
are per person: Users → tick *Transcription* (or `slipdock admin
transcription <email> on|off`, or `PATCH /api/admin/users/:id
{"transcription": true}`; the users list reports `transcription`). Admins
always may.

**Looking at somebody's boards to help them.** Being an admin does not let you
read other people's boards. **Support**, on a person's row under Users, does —
read only, for four hours, and only with a reason, which they are emailed and
which stays on their Account page for good. Their boards are not added to your
own list; while the session lasts they are listed, as links, under **Support
access in force** on Users and in a **Supporting** *name* panel at the top of
your Boards page, where **End now** finishes it early. Sub-boards open from
their parent cards as usual. Demoting or disabling the admin ends it too.

**What it is being used for.** **Overview**, in the avatar menu's **Admin** group, puts
the whole server on one page: how many accounts (admins, disabled, never seen),
how many joined and how many were active in the last 7 and 30 days, and the
boards, lists, cards, wiki pages, files and storage across all of them. Below
that is a row per person — when they signed up, when they were last active, and
what they own — sortable by any column (`?sort=storage`, `cards`, `last_active`,
`signed_up`, `email` and the rest). Things are counted against the **owner** of
the board they are on, sub-boards included, exactly as the limits count them,
so a guest working on your board adds nothing to their own row. *Last active*
is the later of the last browser sign-in and the last use of one of their API
tokens, so an account worked only by an agent still shows as active. It is
read-only; changing anybody's standing is on Users. From a terminal:
`slipdock admin overview [--sort cards]`, or `GET /api/admin/overview` with an
admin-scoped token.

**Admins.** One role, and the oldest account has it after an upgrade. Admins
change all of the above, see everybody, grant and remove admin rights, disable
accounts, set per-person item limits and record who has paid. On Users they can
also **add somebody** by address (they are emailed an invitation when there is
mail, whatever *invites create accounts* says), **change the address** somebody
signs in with (the pencil beside it; the old address is told, and a sign-in link
already sent there stops working), and **close an account** for good, after it
has said what it will take with it and the address has been typed to confirm.
Disable first: it is reversible and immediate, and closing takes their cards and
the boards only they used with it. From a terminal: `slipdock admin add <email>`,
`slipdock admin email <email> <new-email>`, `slipdock admin close <email> --force`
(`POST`, `PATCH` and `DELETE /api/admin/users`, the last with `?confirm=<email>`).
Three things are deliberately refused: mail settings will not save without a
test message that arrived, the last admin cannot be demoted, disabled or closed,
and the admin address only changes once the new address confirms a code.

**When there is no mail server**, sign-in codes are written to a file on the
server (`SLIPDOCK_LOGIN_FALLBACK_PATH`, mode `0600`) and to the log, so a fresh
install can be used at all. Anyone who can read either can sign in as anybody,
so it switches itself off once mail works, and `SLIPDOCK_LOGIN_FALLBACK=false`
forbids it in a way the application cannot undo. Set that on anything other
people can reach. Any off word does the same (`0`, `false`, `no`, `off` or
`none`, in any case), and a value that is neither an off word nor an on word
(`1`, `true`, `yes`, `on`) is named in a warning at boot and turns the file off
too.

A refused address is told exactly what an accepted one is told — "if that
address can sign in here, a link is on its way" — and in the same time, because
the email is sent in the background, so the page cannot be used to find out who
has an account. Asking for links is rate limited (five an hour per address,
twenty per IP; `config :slipdock, :rate_limit, enabled: false` turns that off),
so nobody can use this server to mail strangers. Typing a code counts
separately, per IP and address, so somebody flooding your address with link
requests cannot also stop you entering the code you were sent. All of these
count in memory on this node and are forgotten on restart.

"Per IP" means the visitor's address. Behind a reverse proxy that comes from
`X-Forwarded-For`, believed only from a trusted proxy — loopback by default
(under compose, loopback and the compose network: `compose.yaml` sets `local`),
or the CIDRs in `SLIPDOCK_TRUSTED_PROXIES` (`none` trusts nobody). A proxy
anywhere else, on your LAN or at a public address, has to be listed there, or
every visitor shares its address and its limit.

Browser responses carry a Content-Security-Policy that allows script from this
origin only — see `SlipdockWeb.Plugs.ContentSecurityPolicy`, which explains each
directive and how to replace the header (`config :slipdock, :csp`) if your proxy
sets its own.

Mail goes out over SMTP when `SLIPDOCK_SMTP_HOST` (plus optional
`SLIPDOCK_SMTP_PORT`, `SLIPDOCK_SMTP_USER`, `SLIPDOCK_SMTP_PASSWORD`,
`SLIPDOCK_MAIL_FROM`) is set. Without it, sent mail stays in an in-memory
mailbox at `/dev/mailbox`, and while the sign-in fallback is on (the default
until mail is configured) the code and link are written to
`log/sign-in-links.log` and the server log
(`journalctl -u slipdock | grep "Sign-in code"`). Turn the fallback off and
they are written nowhere; once mail works, sign-in links and codes never reach
the log at all.

Mail comes *in* through Cloudflare Email Routing: an Email Worker posts each
message, signed, to `POST /api/inbound/email`. Set `SLIPDOCK_INBOUND_DOMAIN`
(the domain it is received on) and `SLIPDOCK_INBOUND_SECRET` (shared with the
Worker) to turn it on; with either unset the endpoint answers 404 and nothing
inbound is shown. `SLIPDOCK_INBOUND_SECRET_PREVIOUS` is accepted as well while
the secret is rotated.

**On/off variables all take the same words.** A switch such as
`SLIPDOCK_LOGIN_FALLBACK` or `SLIPDOCK_WELCOME_BOARD` is on for `1`, `true`,
`yes` or `on`, and off for `0`, `false`, `no`, `off` or `none`, in any case and
with spaces around it trimmed. A value left blank, or only spaces, is the same
as leaving the variable unset, so its default applies. A limit such as
`SLIPDOCK_BOARD_LIMIT` takes a positive number or one of the off words, and a
number that isn't one stops the server at boot, naming the variable, rather
than being quietly ignored. `.env.example` lists every variable.

### Signing an agent in

An agent cannot read your email, so it cannot follow a magic link. It gets a
token instead, and there are two ways to give it one. ([Setting up an
agent](../agents.md) is the whole job end to end; this is the credential half of
it.)

**The device flow** (`slipdock auth`, with no token) is the way to do it from
anywhere — a laptop, a sandbox, a container, any machine that is not this
server:

```sh
$ slipdock auth
  Open  https://slipdock.example/activate
  Enter WDJB-MJHT

  Signing in as "slipdock CLI on laptop". Waiting — Ctrl-C to stop.
```

You open `/activate` in a browser where you are already signed in, type the
code, and see what is being asked for — what called itself what, what it would
be allowed to do, where it asked from, and when. Approve it and the agent is
holding a token a few seconds later; refuse it and the agent is told so rather
than left waiting. The code lasts ten minutes and works once.

`--scope read` asks for a token that cannot change anything, and `--label`
names the client on the approval screen. Under the covers this is
[RFC 8628](https://datatracker.ietf.org/doc/html/rfc8628): `POST
/api/auth/device` starts it, `POST /api/auth/device/token` is polled until a
person decides. Neither needs a token, because they are how you get one.

> Approving gives whatever asked a token that acts as you until you revoke it.
> If you did not just start it yourself, refuse it — a code somebody else sends
> you is somebody else asking for access to your account.

**A token you make yourself** suits anything with no human to approve it —
CI, cron, a scheduled job. Create one under **Account → API tokens**, give it
a scope and an expiry, and put it in the secret store. This is the right
answer there: no interactive flow helps a machine that nobody is watching.

**API tokens** carry a scope (read-only or read/write, optionally confined to
named boards) and an optional expiry, and Account › *API tokens* shows when each was
last used and from where. A read-only token is refused any request that would
change something, and a board-scoped one cannot see — or even list — boards
outside its scope. Revoke one and it stops working at once.

### Agentic Login (for automated testing)

> **Not the way to sign an agent in.** Use the device flow above. This exists
> for an agent running *on the server itself*, and it is an authentication
> bypass by design.


Receiving an email is awkward for an automated agent driving the app, so the
sign-in page can also offer an **Agentic Login** button. Enter an email address
and press it instead of "Email me a sign-in link": the server mints the same
one-time link but writes it to a fresh, randomly named file
(`slipdock-agentic-login/slipdock-agentic-login-<random>.txt` under the system temp dir by default, readable only by the account running the server) and shows that filename
on the page. An agent with shell access to the server then reads the file and
opens the link it contains in its browser, then presses **Sign in**. Opening any
sign-in link only shows that button — signing in is the POST it makes, so a mail
scanner that prefetches links cannot use one up. The link works once and expires
in 15 minutes, as usual; the file is left behind for the agent to delete.

It is on in `dev` and `test`. In production it is off unless the server runs
with `SLIPDOCK_AGENTIC_LOGIN=true` (or another on word: `1`, `yes`, `on`, in any
case; and optionally `SLIPDOCK_AGENTIC_LOGIN_DIR` to change the directory). A
value that is neither an on word nor an off word is named in a warning at boot
and leaves it off. Anyone who can reach the sign-in page can create these
files, so only enable it on machines used for automated testing.

**Groups** (`/groups`) are named sets of people you can share with at once.
Members are added by email; the group's creator manages it.

**Sharing** — a board belongs to the user who created it. From the board's
settings the owner can grant *read only*, *can comment* or *can edit* access
to a person or a group; board access covers every card on it and the
sub-boards inside them. **Can comment** (#863) is a reader who may also join
the discussion: comment, post a status update and vote, and take back their
own comments — but not change the card's title, dates, assignees, flags, list,
checklist or anything else. A commenter's card modal keeps the comment box,
status updates and votes live and the rest disabled. A single card can be shared the same way from its modal (by the owner
or anyone who can edit it): the recipient sees that card, listed under
"Cards shared with you" on the home page, and nothing else on the board. A
card grant can also raise a board reader to a commenter or an editor on that
one card. A
saved view can be shared from the Views menu: the recipient opens the board
only through that view, sees just the cards it selects, and can edit them
only if the view grant is "can edit". Readers get a disabled card modal, no
drag and drop, and no add buttons; the server refuses their writes too.

A board somebody shared with you sits on your board list beside your own, and
says **shared by** whoever owns it — on the cards and in the table, and in the
tooltip in full. The API says the same thing in data: every board response
carries `owner` (`id`, `email`, `name`), and a listing marks each board
`shared` when its owner is somebody other than you. `slipdock boards` grows an
OWNER column when any of them are, and `slipdock board <ref>` names the owner
on its own line.

**Giving a share back.** The *…* menu on a board somebody shared with you has
a **Shared** item (`/boards/:id/shared`). The page it opens says who the board
belongs to, who handed it over, when, and on what terms — the board itself, or
a saved view onto it — and carries a **Discard** button. Discarding takes away
the grants that name *you*: the board leaves your list, your switcher and your
search, and nothing on the board changes, so the owner can share it again.
Access that came through a **group** is not yours to give up, so the button is
disabled and the page says what would end it (leaving the group, or the owner
revoking the group's access). Owners have no use for the page and are sent to
their board's settings, which is where sharing out lives.

A **wiki page** can be shared on its own too, and a page grant behaves like a
card grant: the recipient reads (or edits) that page without the board coming
with it. A view grant is the exception that goes the other way — it reaches
cards through the view and never reaches pages at all.

**API tokens** are created under Account, or by the device flow above; the
CLI stores one with `slipdock auth <token>` or gets its own with `slipdock
auth`. See [Signing an agent in](#signing-an-agent-in).

---

← [Moving boards between servers](moving-boards-between-servers.md) · [Contents](../manual.md) · [Roadmap features in the API and CLI](roadmap-features-in-the-api-and-cli.md) →
