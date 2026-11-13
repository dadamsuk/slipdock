[
  {"Install something on the agent's machine",
   [
     {:no, "curl is enough"},
     {:no, "add the address"},
     {:yes, "an escript (Erlang)"},
     {:some, "optional files"},
     {:yes, "a small service"},
     {:no, "nothing"}
   ]},
  {"Works from claude.ai, ChatGPT and the phone apps",
   [
     {:no, "needs a shell"},
     {:yes, "as a connector"},
     {:no, "needs a shell"},
     {:some, "ChatGPT zips"},
     {:some, "scheduled Claude, ChatGPT"},
     {:no, "—"}
   ]},
  {"Read boards and cards, and search",
   [
     {:yes, ""},
     {:yes, ""},
     {:yes, ""},
     {:yes, "through the CLI or MCP"},
     {:some, "the card it was sent"},
     {:some, "the card's fields"}
   ]},
  {"Change cards: move, comment, complete",
   [
     {:yes, ""},
     {:yes, ""},
     {:yes, ""},
     {:yes, "through the CLI or MCP"},
     {:yes, "reports back on its card"},
     {:no, "one way only"}
   ]},
  {"Leave and read a card's handoff (where it was left)",
   [
     {:yes, ""},
     {:yes, "get_card shows it first"},
     {:yes, ""},
     {:yes, "read on claim, written on stopping"},
     {:yes, "its summary, when it stops short"},
     {:no, ""}
   ]},
  {"Make a card recurring, skip or stop one",
   [
     {:yes, "PUT /api/cards/:id/recurrence"},
     {:yes, "update_card's recurrence"},
     {:yes, "slipdock repeat"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"Snooze a card until a day, or wake it",
   [
     {:yes, "POST /api/cards/:id/snooze"},
     {:yes, "update_card's snoozed_until"},
     {:yes, "slipdock snooze, slipdock wake"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"Colour a card's cover and each edge",
   [
     {:yes, "color, border_top, border_right, … on PATCH /api/cards/:id"},
     {:yes, "update_card's color, border_top, border_right, …"},
     {:yes, "slipdock edit --color, --border, --border-top, …"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"Release a batched board's merged work now, see where its releases stand, and lift a red release's hold",
   [
     {:yes, "POST and GET /api/boards/:id/release, DELETE …/release/hold"},
     {:yes, "release_now (check: true to read, lift_hold: true)"},
     {:yes, "slipdock release [--lift-hold], slipdock releases"},
     {:yes, "only when asked: a card is done on merge"},
     {:yes, "a runner's release job fires it"},
     {:no, "one way only"}
   ]},
  {"Read and change what a person sees of a card (their card views)",
   [
     {:yes, "/api/card-views"},
     {:yes, "card_views"},
     {:yes, "slipdock card-view"},
     {:yes, "through the CLI or MCP, when asked"},
     {:yes, "through the CLI or MCP, when asked"},
     {:no, "one way only"}
   ]},
  {"Add a skill source, read a skill, enable it on a board pinned",
   [
     {:yes, "/api/skill-sources, /api/skill-entries, /api/boards/:board/skills"},
     {:yes, "skill_registry"},
     {:yes, "slipdock registry"},
     {:yes, "through the CLI or MCP, when asked"},
     {:yes, "through the CLI or MCP, when asked"},
     {:no, "one way only"}
   ]},
  {"Get the skills enabled on a board, each with its pinned text",
   [
     {:yes, "GET /api/boards/:board/skills"},
     {:yes, "get_guide's board"},
     {:yes, "slipdock skills board"},
     {:yes, "through the CLI or MCP, when planning"},
     {:yes, "through the CLI or MCP, when planning"},
     {:no, "one way only"}
   ]},
  {"Wait on a person, and answer a wait",
   [
     {:yes, "POST /api/cards/:id/wait"},
     {:yes, "update_card's wait, answer_wait"},
     {:yes, "slipdock wait, slipdock answer"},
     {:yes, "open a wait and stop"},
     {:yes, "parks the job; the answer sends it again"},
     {:no, "one way only"}
   ]},
  {"See what is waiting on you, and a board's pulse",
   [
     {:yes, "GET /api/work, /api/boards/:id/pulse"},
     {:yes, "whoami, get_board's pulse"},
     {:yes, "slipdock work, slipdock pulse"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"See what in an epic's tree is waiting on you",
   [
     {:yes, "GET /api/cards/:id, /api/boards/:board: waiting_on_me"},
     {:yes, "get_card, get_board: waiting_on_me"},
     {:yes, "slipdock card, slipdock board: Waiting on you:"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"Dismiss an item, or mute a board, on your Waiting on you",
   [
     {:yes, "POST /api/work/dismissed, POST /api/work/muted"},
     {:yes, "update_card's and update_board's waiting_list"},
     {:yes, "slipdock work --dismiss, --mute"},
     {:yes, "through the CLI or MCP, when asked"},
     {:yes, "through the CLI or MCP, when asked"},
     {:no, "one way only"}
   ]},
  {"Turn the overseer on, set its pace, and read its alerts",
   [
     {:yes, "GET/PATCH /api/boards/:id/overseer"},
     {:yes, "get_board's overseer, update_board's overseer"},
     {:yes, "slipdock overseer"},
     {:yes, "through the CLI or MCP"},
     {:yes, "a runner with job_overseer runs its passes"},
     {:no, "one way only"}
   ]},
  {"See the top cards of lists from several boards (Multiboard)",
   [
     {:yes, "GET /api/multiboard"},
     {:no, "not a tool: use the API or the CLI"},
     {:yes, "slipdock multiboard"},
     {:yes, "through the CLI"},
     {:no, "one way only"},
     {:no, "one way only"}
   ]},
  {"Save a multiboard view by name, for the home page",
   [
     {:yes, "/api/multiboards"},
     {:no, "not a tool: use the API or the CLI"},
     {:yes, "slipdock save-multiboard, multiboards"},
     {:yes, "through the CLI"},
     {:no, "one way only"},
     {:no, "one way only"}
   ]},
  {"Get your addresses for emailing cards and wiki pages onto a board, or rotate them",
   [
     {:yes, "GET /api/boards/:id/inbound, /api/me/inbound (?folder= for a wiki folder's)"},
     {:no, "not a tool: the address is for a person's mail client"},
     {:yes, "slipdock inbound <board>, inbound me, inbound <board> --folder F"},
     {:yes, "through the CLI"},
     {:yes, "through the CLI"},
     {:no, "one way only"}
   ]},
  {"Let other addresses mail a board's card address (permitted senders)",
   [
     {:yes, "PATCH /api/boards/:id inbound_senders"},
     {:no, "not a tool: the board's owner decides who may mail it"},
     {:yes, "slipdock set-board <board> --inbound-senders LIST"},
     {:yes, "through the CLI"},
     {:yes, "through the CLI"},
     {:no, "one way only"}
   ]},
  {"See the email you sent in, and why any bounced",
   [
     {:yes, "GET /api/inbound/log"},
     {:no, "not a tool yet"},
     {:yes, "slipdock inbound log"},
     {:yes, "through the CLI"},
     {:yes, "through the CLI"},
     {:no, "one way only"}
   ]},
  {"Read a board's flow day by day, and how its runners are doing",
   [
     {:yes, "GET /api/boards/:id/flow, /api/boards/:id/runner_stats"},
     {:yes, "get_board's history, runners"},
     {:yes, "slipdock flow, slipdock runner-stats"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"See what is happening right now: which runners are doing what, the cards in progress",
   [
     {:yes, "GET /api/boards/:id/now"},
     {:yes, "get_board's now"},
     {:yes, "slipdock now"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"Record deploys, and read the delivery (DORA) numbers",
   [
     {:yes, "POST /api/deployments, GET /api/boards/:id/dora"},
     {:yes, "get_board's dora"},
     {:yes, "slipdock deploy run, slipdock dora"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"Pause runner work, and see that it is paused",
   [
     {:yes, "POST /api/boards/:id/pause"},
     {:yes, "manage_automation's pause"},
     {:yes, "slipdock pause, slipdock resume"},
     {:yes, "stop when paused"},
     {:yes, "nothing is claimed while paused"},
     {:no, "one way only"}
   ]},
  {"Tidy a board up: see what the gardener found, apply or dismiss",
   [
     {:yes, "GET/POST /api/boards/:board/garden"},
     {:yes, "garden, garden_decide"},
     {:yes, "slipdock garden"},
     {:yes, "through the CLI or MCP"},
     {:yes, "through the CLI or MCP"},
     {:no, "one way only"}
   ]},
  {"Read and write wiki pages",
   [
     {:yes, ""},
     {:yes, ""},
     {:yes, ""},
     {:yes, "and when to"},
     {:some, "through the CLI or MCP"},
     {:no, ""}
   ]},
  {"Attach a board, card or page to a chat yourself",
   [
     {:no, "the agent fetches it"},
     {:yes, "as a resource, from the + menu"},
     {:no, ""},
     {:no, ""},
     {:no, ""},
     {:no, ""}
   ]},
  {"Attach and download files",
   [
     {:yes, ""},
     {:yes, "up to 10 MB each"},
     {:yes, "up to 250 MB, recordings too"},
     {:yes, "through the CLI or MCP"},
     {:no, ""},
     {:no, ""}
   ]},
  {"List and change a board's automations",
   [
     {:yes, ""},
     {:yes, "the board's owner"},
     {:yes, ""},
     {:yes, "through the CLI or MCP"},
     {:no, ""},
     {:no, ""}
   ]},
  {"Connect runners",
   [
     {:yes, ""},
     {:no, ""},
     {:yes, ""},
     {:some, "through the CLI"},
     {:some, "from the board"},
     {:no, ""}
   ]},
  {"Mirror your wiki to a local folder",
   [
     {:no, ""},
     {:no, ""},
     {:yes, "slipdock sync"},
     {:no, ""},
     {:no, ""},
     {:no, ""}
   ]},
  {"The board starts the work",
   [
     {:no, "you start it"},
     {:some, "claim_job in a loop"},
     {:some, "claim-job in a loop"},
     {:some, "slipdock-loop"},
     {:yes, "pushed from a rule"},
     {:yes, "on any rule"}
   ]},
  {"Runs with nobody watching",
   [
     {:some, "if you schedule it"},
     {:some, "if you schedule it"},
     {:some, "if you schedule it"},
     {:yes, "slipdock-loop"},
     {:yes, ""},
     {:yes, ""}
   ]},
  {"Can be limited to read-only",
   [
     {:yes, "read-only token"},
     {:yes, "approve read-only"},
     {:yes, "read-only token"},
     {:yes, "follows the token"},
     {:some, "its token takes jobs only"},
     {:no, "—"}
   ]},
  {"Signs in with",
   [
     {:text, "approve a code, or a token"},
     {:text, "the browser (OAuth), or a token"},
     {:text, "slipdock auth"},
     {:text, "whatever the agent uses"},
     {:text, "a runner token"},
     {:text, "nothing: it calls out"}
   ]}
]
