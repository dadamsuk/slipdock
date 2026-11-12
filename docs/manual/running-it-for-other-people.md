[Slipdock — the manual](../manual.md)

## Running it for other people

Slipdock is built for one person or a team who trust each other, and it will
also run as a small shared service. A handful of things make that difference,
all under **Configuration → Server**, with the people themselves under
**Users**:

- **Who may register** — closed, an allowlist, approval one at a time, or open.
- **An item limit for free accounts**, counted against the boards somebody
  *owns*, so a guest working on your board costs them nothing. An item is a
  card, a wiki page or an uploaded file — all three count, or writing the work
  up as pages would be a way round it.
- **A free trial**: free accounts stop being able to add anything so many days
  after they were made. Off by default. It is independent of the item limit —
  an account can have no item limit at all and still run out of trial, or have
  both and hit whichever comes first. Nothing is deleted and nobody is locked
  out: an expired account reads and edits everything it has.
- **What it is being used for**, under **Overview** (admins only, in the
  avatar menu's Admin group; `slipdock admin overview` from a terminal): how many accounts,
  how many joined or were active in the last 7 and 30 days, and for each
  person when they signed up, when they were last active (signing in or using
  an API token), and how many boards, lists, cards, wiki pages and files they
  own and the storage behind them. Sort the table by any column.
- **Who has paid**, per person under **Users** (Manage on their row opens the
  panel with their limit, paid-up date, permissions and support access): a paid-up date takes somebody
  off the free allowance and off the trial clock. There is no billing in
  Slipdock; whoever takes the money sets the date.
- **Who people can see** — everyone on the server, or only the people they
  actually share a board, card or page with. The second is what stops two
  customers of one server learning that the other exists; it also keeps their
  addresses out of the prompts sent to a language model.
- **Whether sharing with a stranger makes them an account**, which is how
  somebody arrives on a hosted instance and is usually wrong on a private one.
- **Product analytics and error tracking with PostHog**, off until you fill
  in a project key (and, for the EU cloud or a proxy, a host). With one, pages
  send pageviews and their uncaught JavaScript errors, and the server sends
  its own errors and crashes (anything logged at error level, with the stack
  trace) as `$exception` events to PostHog's Error Tracking — at most 30 a
  minute, so a crash loop cannot flood the project. Without a key nothing
  about PostHog reaches a browser and the server sends nothing — no script, no
  requests, no widened Content-Security-Policy. From a terminal: `slipdock admin set
  posthog_key=phc_... posthog_host=https://eu.i.posthog.com`, and
  `posthog_key=` to turn it off again.
- **Whose AI key search and automations use.** Semantic search, the search
  index and scheduled automations run with nobody signed in, so they spend one
  admin's AI settings, chosen on the Configuration page (`slipdock admin set
  ai_system_user=you@example.com`). The page shows what is in effect and why.

### The ceilings, which are not about selling anything

Separately from all of that, **every install has three ceilings on, however it
is run** — a server you host for yourself included:

| Ceiling | Default | Counts |
| --- | --- | --- |
| Boards one person may own | 1,000 | Root boards. Sub-boards, the ones behind subcards, do not count. |
| Items on one person's boards | 250,000 | Cards, wiki pages and uploaded files together. |
| Files on one person's boards | 10 GB | The size of every attachment behind them. |

They are a safety rail rather than a price list: a runaway script or an import
gone wrong should hit something. **Admins are not exempt** — an admin who means
to go past one raises it, which takes a moment and leaves a record of the
decision. Each has its own switch, so any of them can be turned off without
losing the number behind it, and where a free account's own allowance is lower
than the ceiling, the lower one wins.

### Settings: the environment seeds them once

Everything about *how this server behaves* — who may register, the free
allowance and the trial, the ceilings, who shows up in people pickers, whether sharing something with a
stranger makes them an account, and how mail is sent — lives in the database
now, so it can be changed from a browser without a redeploy.

The environment still configures it, but only as a **seed**: the variables
below are written into the settings the first time the server starts, and are
ignored from then on.

```sh
# On/off variables all take the same words, in any case and trimmed:
#   on:  1, true, yes, on        off: 0, false, no, off, none
# A value left blank (or only spaces) is the same as unset. A limit takes a
# positive number or an off word, and a number that isn't one stops the boot.
SLIPDOCK_ADMIN_EMAIL=you@example.com   # setting this skips the setup wizard entirely
SLIPDOCK_SIGNUP_MODE=allowlist         # open | allowlist | approval | closed
SLIPDOCK_SIGNUP_ALLOW=you@example.com,example.org   # seeds the allowlist
SLIPDOCK_FREE_CARD_LIMIT=20            # items allowed on one free account's own boards
SLIPDOCK_TRIAL_DAYS=30                 # free accounts stop adding after this long (unset = no trial)
SLIPDOCK_BOARD_LIMIT=1000              # boards one person may own; 0 or "off" for no ceiling
SLIPDOCK_ITEM_LIMIT=250000             # cards, pages and files together; 0 or "off" for none
SLIPDOCK_STORAGE_LIMIT_MB=10240        # uploaded files, in MB; 0 or "off" for no ceiling
SLIPDOCK_USER_DIRECTORY=shared_only    # instance | shared_only
SLIPDOCK_INVITES_CREATE_ACCOUNTS=false # whether sharing with a stranger makes an account
SLIPDOCK_SMTP_HOST=smtp.example.com    # and SLIPDOCK_SMTP_PORT / _USER / _PASSWORD / _FROM
SLIPDOCK_LOGIN_FALLBACK=false          # never write sign-in codes to a file (set this when public)
```

There is a command-line equivalent for an install that was not configured that
way, and a `--status` that says what the server currently thinks:

```sh
mix slipdock.setup --admin you@example.com --mode allowlist --allow example.com
mix slipdock.setup --status
mix slipdock.setup --sign-in-link you@example.com   # when mail has broken
mix slipdock.setup --make-admin you@example.com     # a server with no usable admin
```

It refuses to run on a server that is already set up — that server is already
somebody's.

**Changing one of these on a server that has already started does nothing.**
That is deliberate — a browser has to be able to win, or the settings page
would be a lie — but it does mean a variable edited after the fact looks
ignored, because it is. Change it in the app instead.

Two exceptions, which are overrides rather than seeds and win every time:
`SLIPDOCK_LOGIN_FALLBACK=false`, so a public host can forbid writing sign-in
codes to a file whatever the settings say, and `SLIPDOCK_AGENTIC_LOGIN`.
Both take the same words as every other switch: on is `1`, `true`, `yes` or
`on`, off is `0`, `false`, `no`, `off` or `none`, in any case. Any other value
is named in a warning at boot and read as off: no sign-in codes in a file, and
no Agentic Login.

---

← [Docker, step by step](docker-step-by-step.md) · [Contents](../manual.md) · [Receiving email](receiving-email.md) →
