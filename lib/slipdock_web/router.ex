defmodule SlipdockWeb.Router do
  use SlipdockWeb, :router

  import SlipdockWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SlipdockWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug SlipdockWeb.Plugs.ContentSecurityPolicy
    # Says so, once, when this server is reached by a name it does not know
    # itself by. Warns and carries on; it never refuses.
    plug SlipdockWeb.Origin
    plug :fetch_current_user
    # A server nobody has set up yet has one page, and this is how you get sent
    # to it.
    plug SlipdockWeb.Plugs.Setup, :redirect_to_setup
  end

  # Only while this server has not been set up. 404 once it has.
  pipeline :unclaimed_only do
    plug SlipdockWeb.Plugs.Setup, :require_unclaimed
  end

  # Administering the server over HTTP. Needs an admin account *and* a token
  # deliberately made with the `admin` scope, so the tokens that live in agents
  # and CI cannot change who may register.
  pipeline :api_admin do
    plug :accepts, ["json"]
    plug :fetch_api_user
    plug :require_api_admin
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_api_user
    plug :require_token_write
  end

  # `/api/wiki/...`: the caller's own wiki, which its address doesn't name.
  pipeline :own_wiki do
    plug SlipdockWeb.Plugs.OwnWiki
  end

  # The agent guide: readable without a token, richer with one.
  pipeline :api_guide do
    plug :maybe_fetch_api_user
  end

  # The device-authorization endpoints. No token plug at all: these are how a
  # client gets a token, so requiring one would be circular. What guards them
  # is the code entropy and the rate limits in the controller.
  pipeline :api_public do
    plug :accepts, ["json"]
  end

  scope "/", SlipdockWeb do
    pipe_through :browser

    # The link in the email only shows a button; signing in is the POST it
    # makes. A GET that signed in would let a mail scanner prefetching links
    # use the token up, and a page elsewhere sign a victim into its account.
    # Signing in with a passkey (#828). Before `/login/:token`, which would
    # read `passkey` as a token.
    post "/login/passkey/options", SessionController, :passkey_options
    post "/login/passkey", SessionController, :passkey
    get "/login/:token", SessionController, :confirm
    post "/login/:token", SessionController, :create
    delete "/logout", SessionController, :delete

    # Approving an agent's request to sign in. Signed-in people only, and the
    # decision is a POST with CSRF — never a GET, so a link cannot approve
    # itself when opened.
    get "/activate", DeviceActivationController, :show
    post "/activate", DeviceActivationController, :decide

    # Setting the server up. Outside every authentication pipeline, because
    # there is nobody to authenticate yet, and gone the moment it is used.
    scope "/setup" do
      pipe_through :unclaimed_only

      live_session :setup,
        on_mount: [
          {SlipdockWeb.SetupLive.Index, :ensure_unclaimed},
          {SlipdockWeb.ViewportHook, :default},
          {SlipdockWeb.StaleAssetsHook, :default}
        ] do
        live "/", SetupLive.Index, :index
      end
    end

    live_session :public,
      on_mount: [
        {SlipdockWeb.UserAuth, :redirect_if_user_is_authenticated},
        {SlipdockWeb.ViewportHook, :default},
        {SlipdockWeb.StaleAssetsHook, :default}
      ] do
      live "/login", LoginLive.Index, :index
    end

    # Help: the app's guides, and connecting an agent. Readable signed out — the question comes
    # before the account — and signed in alike, so it has no redirect.
    live_session :help,
      on_mount: [
        {SlipdockWeb.UserAuth, :mount_current_user},
        {SlipdockWeb.ViewportHook, :default},
        {SlipdockWeb.StaleAssetsHook, :default},
        {SlipdockWeb.NotifyHook, :default}
      ] do
      live "/help", HelpLive.Index, :index
      live "/help/agents", HelpLive.Index, :agents
      live "/help/agents/cli/reference", HelpLive.Index, :cli_reference
      live "/help/agents/flow", HelpLive.Index, :flow
      live "/help/agents/:topic", HelpLive.Index, :agent_topic
      live "/help/:section", HelpLive.Index, :section
    end

    # Published saved views: readable by anyone with the link.
    live_session :published,
      on_mount: [
        {SlipdockWeb.UserAuth, :mount_current_user},
        {SlipdockWeb.ViewportHook, :default},
        {SlipdockWeb.StaleAssetsHook, :default}
      ] do
      live "/p/:token", PublicLive.Show, :show
      # A published wiki page: the prose is current, the answers are a
      # snapshot, and nothing is followable (see `SlipdockWeb.PublicLive.Page`).
      live "/w/:token", PublicLive.Page, :show
    end

    # An image a published page embeds (#1166), to anyone with the page's
    # link, for as long as it is published (`Slipdock.Wiki.Embeds.published?/2`).
    get "/w/:token/files/:id/:name", PublishedFileController, :show
  end

  if Application.compile_env(:slipdock, :dev_routes) do
    scope "/dev" do
      pipe_through :browser
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Setting an agent up: a shell script that installs the skills and saves this
  # server's address. Outside every pipeline on purpose — it is plain text for
  # a machine with nothing on it, so it needs neither a session nor HTML.
  scope "/", SlipdockWeb do
    get "/install.sh", InstallController, :show
    get "/install.ps1", InstallController, :powershell
    # The CLI itself, and its installers (see `SlipdockWeb.CLIInstallController`).
    get "/cli/install.sh", CLIInstallController, :install_sh
    get "/cli/install.ps1", CLIInstallController, :install_ps1
    get "/cli/slipdock.escript", CLIInstallController, :escript
    get "/cli/SHA256SUMS", CLIInstallController, :sums
    get "/cli/slipdock.escript.sig", CLIInstallController, :signature
    # Where the shell and PowerShell runners were served, retired for the
    # runner daemon (#2582): 410 Gone, pointing at Machines.
    get "/runner/*path", RetiredRunnerController, :gone
    # Recording deploys from CI: worked examples (see `SlipdockWeb.DeployExamplesController`).
    get "/deploy/examples/:name", DeployExamplesController, :show
  end

  # The runner protocol (see `SlipdockWeb.API.RunnerController`): plain text,
  # and its own token, so outside the JSON pipelines altogether.
  scope "/api/runner", SlipdockWeb.API do
    post "/claim", RunnerController, :claim
    post "/jobs/:id/heartbeat", RunnerController, :heartbeat
    post "/jobs/:id/transcript", RunnerController, :transcript
    post "/jobs/:id/finish", RunnerController, :finish
  end

  # Recording deploys from CI (see `SlipdockWeb.API.DeploymentController`):
  # JSON, but with the board's deploy token rather than an API token.
  scope "/api/deployments", SlipdockWeb.API do
    pipe_through :api_public

    get "/last", DeploymentController, :last
    post "/", DeploymentController, :create
    post "/failed", DeploymentController, :failed
    patch "/:id", DeploymentController, :finish
  end

  # Short-lived, single-use upload and download links (#1147): the secret in
  # the URL is the authority, so no bearer token (see
  # `SlipdockWeb.API.TransferController`).
  scope "/api", SlipdockWeb.API do
    pipe_through :api_public

    post "/upload/:secret", TransferController, :upload
    get "/download/:secret", TransferController, :download
  end

  # Mail from the Cloudflare Email Worker (#1236, W-1933). No token: the
  # request is signed with SLIPDOCK_INBOUND_SECRET, which is its authority.
  scope "/api", SlipdockWeb.API do
    post "/inbound/email", InboundController, :email
  end

  # The board as an MCP server (see `SlipdockWeb.MCP.Plug`). Outside every
  # pipeline: it does its own bearer auth, because the `:api` pipeline refuses
  # every POST from a read token and every MCP call is a POST, and it reads its
  # own body (the endpoint skips `Plug.Parsers` for it).
  forward "/mcp", SlipdockWeb.MCP.Plug

  scope "/", SlipdockWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Where vaults were (#752): the same place in the one wiki now.
    get "/vaults", WikiRedirectController, :show
    get "/vaults/*rest", WikiRedirectController, :show

    get "/attachments/:id/:filename", AttachmentController, :show
    # An image in a wiki page not saved yet, for its writer alone (#1532).
    get "/autosave-files/:id/:filename", AutosaveFileController, :show
    # A Tool's skill as claude.ai's or ChatGPT's upload takes it (#963).
    get "/tools/:slug/download/:skill/claude.zip", ToolDownloadController, :claude
    get "/tools/:slug/download/:skill/chatgpt.zip", ToolDownloadController, :chatgpt
    get "/tools/:slug/download/package.tar.gz", ToolDownloadController, :package
    # A file in a wiki that is not a page: a synced vault's images and PDFs.
    get "/wiki-files/:id/:name", WikiFileController, :show
    # A meeting page's recording, streamed from its vault owner's Google
    # Drive (W-1690): the player's audio source.
    get "/wiki-pages/:id/recording", RecordingController, :show
    # An Excalidraw drawing's preview, as SVG: `kind` is page or file.
    get "/wiki-drawings/:kind/:id", WikiDrawingController, :show
    # Everything you have, as a zip. Yours, so you do not have to ask.
    get "/account/export.zip", ExportController, :account
    # Board trees as one portable JSON document — the file an import reads.
    get "/account/boards.json", ExportController, :portable
    # Connecting a Google Drive, for meeting recordings (W-1690).
    get "/account/google/connect", GoogleController, :connect
    get "/account/google/callback", GoogleController, :callback
    delete "/account/google", GoogleController, :disconnect
    # Adding a passkey (#828): a challenge, then the authenticator's answer.
    post "/account/passkeys/options", PasskeyController, :options
    post "/account/passkeys", PasskeyController, :create
    get "/boards/:id/export.csv", ExportController, :table
    # The board's wiki as a folder of Markdown: the escape hatch.
    get "/boards/:id/wiki.zip", ExportController, :wiki
    # One page as Markdown, front matter and all — the same file the zip holds.
    get "/boards/:id/wiki/:slug/page.md", ExportController, :page

    # Admins only. Its own live session so `:ensure_admin` applies to the whole
    # of it rather than being remembered per page.
    live_session :admin,
      on_mount: [
        {SlipdockWeb.UserAuth, :ensure_authenticated},
        {SlipdockWeb.UserAuth, :ensure_admin},
        {SlipdockWeb.ViewportHook, :default},
        {SlipdockWeb.StaleAssetsHook, :default},
        {SlipdockWeb.AlertsHook, :default},
        {SlipdockWeb.QuickAddHook, :default},
        {SlipdockWeb.ShortcutsHook, :default},
        {SlipdockWeb.PageLinkHook, :default},
        {SlipdockWeb.NotifyHook, :default}
      ] do
      live "/users", UsersLive.Index, :index
      live "/users/signups", UsersLive.Index, :signups
      live "/overview", OverviewLive.Index, :index
      live "/config", ConfigLive.Index, :index
      live "/config/mail", ConfigLive.Index, :mail
      live "/config/ai", ConfigLive.Index, :ai
      # Tools waiting for an admin to list them for everyone (#964).
      live "/admin/tools", ToolLive.Review, :index
    end

    live_session :authenticated,
      on_mount: [
        {SlipdockWeb.UserAuth, :ensure_authenticated},
        {SlipdockWeb.ViewportHook, :default},
        {SlipdockWeb.StaleAssetsHook, :default},
        {SlipdockWeb.AlertsHook, :default},
        {SlipdockWeb.QuickAddHook, :default},
        {SlipdockWeb.ShortcutsHook, :default},
        {SlipdockWeb.PageLinkHook, :default},
        {SlipdockWeb.NotifyHook, :default}
      ] do
      live "/", BoardLive.Index, :index
      live "/work", WorkLive.Index, :index
      # Semantic search across everything the reader can see, and the
      # assistant that uses it as a tool (see `Slipdock.Search`).
      # One page, two modes: Search hands back the cards, Ask hands back an
      # answer. The mode is the route so it is linkable and the back button
      # works through it.
      live "/search", SearchLive.Index, :search
      live "/ask", SearchLive.Index, :ask
      # The account area is a page per section rather than one long scroll:
      # who you are, the preferences, signing in, the tokens, and moving work
      # in and out. They share a LiveView (and so a side nav, #1737) because
      # they share the person they are about.
      live "/account", AccountLive.Index, :index
      live "/account/settings", AccountLive.Index, :settings
      live "/account/sign-in", AccountLive.Index, :sign_in
      live "/account/tokens", AccountLive.Index, :tokens
      live "/account/data", AccountLive.Index, :data
      # The machines running the runner daemon for this account (#2570), and
      # the page that approves one's enrolment by its code.
      live "/account/machines", AccountLive.Index, :machines
      live "/account/machines/approve", AccountLive.MachineApprove, :show
      # One machine (#2572): its owner manages its runners there, and a
      # member of a board it serves sees it.
      live "/machines/:id", MachinesLive.Show, :show
      # How to point an agent at this server. A page rather than a doc because
      # the one thing it has to get right is this install's own address.
      live "/account/agent", AccountLive.Index, :agent
      # Your last 50 inbound emails and what came of each (#1290): only while
      # this server takes mail.
      live "/account/email-log", AccountLive.Index, :email_log
      live "/groups", GroupLive.Index, :index
      live "/templates", TemplateLive.Index, :index
      # Tools (#958): packaged docs, a board and skills people share here.
      live "/tools", ToolLive.Index, :index
      live "/tools/:slug", ToolLive.Show, :show
      # Skills from elsewhere (#2059): sources a user adds by URL, fetched and kept.
      live "/skills", SkillRegistryLive.Index, :index
      live "/skills/entries/:id", SkillRegistryLive.Index, :entry
      live "/favourites", FavouriteLive.Index, :index
      # What a card shows, per person: global, board and list (#2031).
      live "/card-views", CardViewLive.Index, :index
      # The top cards of lists picked from any board, on one page (#1479).
      live "/multiboard", MultiboardLive.Index, :index
      live "/multiboard/:id", MultiboardLive.Index, :show
      # The person's one wiki (W-2201): their Knowledge Base, then a folder
      # for each board, its pages at their paths, the same paths as the
      # files on disk. `.settings` can't be a note's name (Obsidian hides
      # dotfiles), so it can't shadow one.
      live "/wiki", WikiLive.Index, :vault
      live "/wiki/.settings", VaultLive.Index, :settings
      live "/wiki/*path", WikiLive.Index, :vault
      # The board's wiki: a tree of Markdown pages beside its cards.
      live "/boards/:id/wiki", WikiLive.Index, :index
      live "/boards/:id/wiki/new", WikiLive.Index, :new
      live "/boards/:id/wiki/:slug", WikiLive.Index, :show
      live "/boards/:id/wiki/:slug/edit", WikiLive.Index, :edit
      # An Excalidraw drawing in the Excalidraw editor: `kind` is page (the
      # plugin's .excalidraw.md) or file (a .excalidraw).
      live "/drawings/:kind/:id", DrawingLive, :show
      # Any other wiki file that is not a page, in a viewer: an image, a PDF,
      # JSON, CSV, text (see `SlipdockWeb.FileLive`).
      live "/files/:id", FileLive, :show
      # Shared with me (#817): pages and folders other people shared, with
      # nothing of the boards they are on.
      live "/shared", SharedLive, :index
      live "/shared/pages/:id", SharedLive, :page
      live "/shared/pages/:id/edit", SharedLive, :edit
      live "/shared/folders/:id", SharedLive, :folder
      live "/boards/:id/wiki/:slug/history", WikiLive.Index, :history
      live "/boards/:id/wiki/:slug/history/:rev", WikiLive.Index, :revision
      live "/boards/:id/tidy", GardenLive.Index, :index
      # What the health monitor found stuck (W-2310).
      live "/boards/:id/health", HealthLive.Index, :index
      # What is happening right now: runners, cards in progress, queued jobs (#2103).
      live "/boards/:id/now", NowLive.Index, :index
      # What passes learned, to triage (W-2310 §Findings, #1940).
      live "/boards/:id/findings", FindingsLive.Index, :index
      # What shipped since yesterday, with its evidence (#1948).
      live "/boards/:id/ledger", LedgerLive.Index, :index
      # How agents build on the board: its agent settings (#2011).
      live "/boards/:id/agentic", AgenticLive.Index, :index
      # A board's flow, velocity, runners and delivery on one page (#1185).
      live "/boards/:id/visualise", BoardLive.Visualise, :index
      live "/boards/:id", BoardLive.Show, :show
      # The receiving end of a share: who handed this board over, and the way
      # out of it. A page of its own because it is not part of the board.
      live "/boards/:id/shared", BoardLive.Shared, :show
      live "/boards/:id/cards/:card_id", BoardLive.Show, :card
      live "/boards/:id/tags", BoardLive.Show, :tags
      live "/boards/:id/activity", BoardLive.Show, :activity
      live "/boards/:id/archive", BoardLive.Show, :archive
      live "/boards/:id/settings", BoardLive.Show, :settings
      live "/boards/:id/automations", BoardLive.Show, :automations
      live "/boards/:id/swimlanes", BoardLive.Show, :swimlanes
      live "/boards/:id/swimlanes/cards/:card_id", BoardLive.Show, :swimlanes_card
      live "/boards/:id/swimlanes/tags", BoardLive.Show, :swimlanes_tags
      live "/boards/:id/swimlanes/activity", BoardLive.Show, :swimlanes_activity
      live "/boards/:id/swimlanes/archive", BoardLive.Show, :swimlanes_archive
      live "/boards/:id/swimlanes/settings", BoardLive.Show, :swimlanes_settings
      live "/boards/:id/swimlanes/automations", BoardLive.Show, :swimlanes_automations
      live "/boards/:id/table", BoardLive.Show, :table
      live "/boards/:id/table/cards/:card_id", BoardLive.Show, :table_card
      live "/boards/:id/table/tags", BoardLive.Show, :table_tags
      live "/boards/:id/table/activity", BoardLive.Show, :table_activity
      live "/boards/:id/table/archive", BoardLive.Show, :table_archive
      live "/boards/:id/table/settings", BoardLive.Show, :table_settings
      live "/boards/:id/table/automations", BoardLive.Show, :table_automations
      live "/boards/:id/timeline", BoardLive.Show, :timeline
      live "/boards/:id/timeline/cards/:card_id", BoardLive.Show, :timeline_card
      live "/boards/:id/timeline/tags", BoardLive.Show, :timeline_tags
      live "/boards/:id/timeline/activity", BoardLive.Show, :timeline_activity
      live "/boards/:id/timeline/archive", BoardLive.Show, :timeline_archive
      live "/boards/:id/timeline/settings", BoardLive.Show, :timeline_settings
      live "/boards/:id/timeline/automations", BoardLive.Show, :timeline_automations
      live "/boards/:id/calendar", BoardLive.Show, :calendar
      live "/boards/:id/calendar/cards/:card_id", BoardLive.Show, :calendar_card
      live "/boards/:id/calendar/tags", BoardLive.Show, :calendar_tags
      live "/boards/:id/calendar/activity", BoardLive.Show, :calendar_activity
      live "/boards/:id/calendar/archive", BoardLive.Show, :calendar_archive
      live "/boards/:id/calendar/settings", BoardLive.Show, :calendar_settings
      live "/boards/:id/calendar/automations", BoardLive.Show, :calendar_automations
      live "/boards/:id/outline", BoardLive.Show, :outline
      live "/boards/:id/outline/cards/:card_id", BoardLive.Show, :outline_card
      live "/boards/:id/outline/tags", BoardLive.Show, :outline_tags
      live "/boards/:id/outline/activity", BoardLive.Show, :outline_activity
      live "/boards/:id/outline/archive", BoardLive.Show, :outline_archive
      live "/boards/:id/outline/settings", BoardLive.Show, :outline_settings
      live "/boards/:id/outline/automations", BoardLive.Show, :outline_automations
      live "/boards/:id/narrative", BoardLive.Show, :narrative
      live "/boards/:id/narrative/cards/:card_id", BoardLive.Show, :narrative_card
      live "/boards/:id/narrative/tags", BoardLive.Show, :narrative_tags
      live "/boards/:id/narrative/activity", BoardLive.Show, :narrative_activity
      live "/boards/:id/narrative/archive", BoardLive.Show, :narrative_archive
      live "/boards/:id/narrative/settings", BoardLive.Show, :narrative_settings
      live "/boards/:id/narrative/automations", BoardLive.Show, :narrative_automations
      live "/boards/:id/prioritise", BoardLive.Show, :prioritise
      live "/boards/:id/prioritise/cards/:card_id", BoardLive.Show, :prioritise_card
      live "/boards/:id/prioritise/tags", BoardLive.Show, :prioritise_tags
      live "/boards/:id/prioritise/activity", BoardLive.Show, :prioritise_activity
      live "/boards/:id/prioritise/archive", BoardLive.Show, :prioritise_archive
      live "/boards/:id/prioritise/settings", BoardLive.Show, :prioritise_settings
      live "/boards/:id/prioritise/automations", BoardLive.Show, :prioritise_automations
    end
  end

  scope "/api", SlipdockWeb.API do
    pipe_through :api_public

    post "/auth/device", DeviceController, :create
    post "/auth/device/token", DeviceController, :token

    # A runner daemon enrolling its machine (#2570), and an enrolled machine
    # asking who it is with its machine key, which is not an API token.
    post "/machines/enrol", MachineController, :enrol
    post "/machines/enrol/token", MachineController, :token
    get "/machine", MachineController, :me
    # Its runners' typed configs (a long-poll), its ceiling, and what it did
    # with each config (#2571): the machine key again.
    get "/machine/config", MachineController, :config
    get "/machine/setup-prompt", MachineController, :machine_setup_prompt
    put "/machine/ceiling", MachineController, :ceiling
    post "/machine/runners/:runner_id/report", MachineController, :report
  end

  # Signing in from a third-party app with OAuth (W-21). Discovery and
  # registration need no token, for the same reason the device endpoints do:
  # they are how a client gets one. Registration is rate limited in the
  # controller, and grants nothing until a person approves it.
  scope "/", SlipdockWeb.OAuth do
    pipe_through :api_public

    get "/.well-known/oauth-protected-resource", MetadataController, :protected_resource
    get "/.well-known/oauth-protected-resource/mcp", MetadataController, :protected_resource
    get "/.well-known/oauth-authorization-server", MetadataController, :authorization_server
    post "/oauth/register", RegistrationController, :create
    post "/oauth/token", TokenController, :create
  end

  # The consent page. Signed-in people only — a signed-out one is sent to sign
  # in and brought back — and the decision is a POST with CSRF, never a GET.
  scope "/oauth", SlipdockWeb.OAuth do
    pipe_through [:browser, :require_authenticated_user]

    get "/authorize", AuthorizeController, :show
    post "/authorize", AuthorizeController, :decide
  end

  scope "/api/admin", SlipdockWeb.API do
    pipe_through :api_admin

    get "/settings", AdminController, :settings
    patch "/settings", AdminController, :update_settings
    post "/allowlist", AdminController, :allow
    delete "/allowlist", AdminController, :disallow
    get "/overview", AdminController, :overview
    get "/users", AdminController, :users
    post "/users", AdminController, :create_user
    patch "/users/:id", AdminController, :update_user
    delete "/users/:id", AdminController, :delete_user
    get "/signups", AdminController, :signups
    post "/signups/:id/:decision", AdminController, :decide_signup
  end

  scope "/api", SlipdockWeb.API do
    pipe_through :api_guide

    get "/guide", GuideController, :show

    # The agent skills this app ships (see `Slipdock.Skills`). Like the guide,
    # they need no token: they say how to call the API, not what is on it.
    # Every skill in one gzipped tar — what `/install.sh` unpacks. A machine
    # with only `curl` and `tar` cannot walk the JSON file list below.
    get "/skills.tar.gz", SkillController, :archive
    # Its signature with the release key, when the release job made one
    # (#2784): the runner daemon installs the archive only if it verifies.
    get "/skills.tar.gz.sig", SkillController, :signature

    get "/skills", SkillController, :index
    # One skill rewritten for ChatGPT (see `Slipdock.Skills.ChatGPT`), as the
    # zip its skill upload takes. Before the catch-all, which would read it as
    # a file of the skill.
    get "/skills/:name/chatgpt.zip", SkillController, :chatgpt
    get "/skills/:name", SkillController, :show
    get "/skills/:name/*file", SkillController, :show
  end

  # The caller's one wiki (W-2201): every board they own as one tree of
  # files, with their Knowledge Base first. The same actions as
  # `/api/vaults/:id/...`, the wiki being the caller's own (`OwnWiki`).
  scope "/api/wiki", SlipdockWeb.API do
    pipe_through [:api, :own_wiki]

    patch "/", VaultController, :update
    get "/locate", VaultController, :locate
    get "/resolve", VaultController, :resolve
    get "/wanted", VaultController, :wanted
    get "/changes", VaultController, :changes
    get "/sync", VaultSyncController, :index
    get "/sync/pages/:page", VaultSyncController, :show_page
    put "/sync/pages", VaultSyncController, :put_page
    put "/sync/pages/:page", VaultSyncController, :put_page
    delete "/sync/pages/:page", VaultSyncController, :delete_page
    get "/sync/files/:file", VaultSyncController, :show_file
    post "/sync/files", VaultSyncController, :post_file
    post "/sync/files/:file_id", VaultSyncController, :post_file
    patch "/sync/files/:file_id", VaultSyncController, :patch_file
    delete "/sync/files/:file_id", VaultSyncController, :delete_file
  end

  scope "/api", SlipdockWeb.API do
    pipe_through :api

    get "/me", MeController, :show
    # The caller's machines (#2570): list, one, a one-time enrolment key,
    # revoke, and an enrolment looked up and decided by its code.
    get "/machines", MachineController, :index
    post "/machines/enrolment-keys", MachineController, :create_key
    get "/machines/enrolment", MachineController, :enrolment
    post "/machines/enrolment/approve", MachineController, :approve
    post "/machines/enrolment/refuse", MachineController, :refuse
    get "/machines/:id", MachineController, :show
    # Renamed by its owner (#2666): `name`, what the pages show.
    patch "/machines/:id", MachineController, :rename
    delete "/machines/:id", MachineController, :revoke
    # A machine's runners, configured as typed data (#2571).
    post "/machines/:id/runners", MachineController, :add_runner
    patch "/machines/:id/runners/:runner_id", MachineController, :set_runner
    delete "/machines/:id/runners/:runner_id", MachineController, :remove_runner
    # Pause or resume one, and ask the daemon to update now (#2572).
    post "/machines/:id/runners/:runner_id/pause", MachineController, :pause_runner
    post "/machines/:id/runners/:runner_id/resume", MachineController, :resume_runner
    post "/machines/:id/update", MachineController, :request_update
    # Send a runner a probe, and read its latest (#2580).
    post "/machines/:id/runners/:runner_id/probe", MachineController, :probe
    get "/machines/:id/runners/:runner_id/probe", MachineController, :show_probe
    get "/machines/:id/setup-prompt", MachineController, :setup_prompt
    # The caller's own inbound mail and what came of it (#1242).
    get "/inbound/log", InboundController, :log
    # The caller's own inbound addresses (#1246): personal, and per board.
    get "/me/inbound", InboundController, :me
    post "/me/inbound", InboundController, :update_me
    post "/me/inbound/rotate", InboundController, :rotate_me
    get "/boards/:board/inbound", InboundController, :board
    post "/boards/:board/inbound/rotate", InboundController, :rotate_board
    # The caller's own work: waiting on them, then assigned by due (#1118).
    get "/work", WorkController, :index
    # Taking things off one's own Waiting on you (#2069).
    get "/work/dismissed", WorkController, :dismissed
    post "/work/dismissed", WorkController, :dismiss
    delete "/work/dismissed/:card", WorkController, :undismiss
    post "/work/muted", WorkController, :mute
    delete "/work/muted/:board", WorkController, :unmute
    # The multiboard overview (#1479): the top cards of lists from any board.
    get "/multiboard", MultiboardController, :index
    # Saved multiboards (#1482): named views, on the caller's home page.
    get "/multiboards", MultiboardController, :saved
    post "/multiboards", MultiboardController, :create
    get "/multiboards/:id", MultiboardController, :show
    patch "/multiboards/:id", MultiboardController, :update
    delete "/multiboards/:id", MultiboardController, :delete

    # Tools (#958): packages of docs, files, a board blueprint and skills.
    get "/tools", ToolController, :index
    post "/tools", ToolController, :create
    get "/tools/:slug", ToolController, :show
    post "/tools/:slug/install", ToolController, :install
    post "/tools/:slug/listing", ToolController, :request_listing
    # A Tool's skills: all of them as one tar for a skills directory, or one
    # as the zip claude.ai or ChatGPT takes (#962).
    get "/tools/:slug/skills.tar.gz", ToolController, :skills_archive
    get "/tools/:slug/skills/:skill/claude.zip", ToolController, :claude_zip
    get "/tools/:slug/skills/:skill/chatgpt.zip", ToolController, :chatgpt_zip
    # One file of a Tool by its path in the package (#1156): what a stub skill
    # fetches its procedure from at run time, the latest version unless asked.
    get "/tools/:slug/files/*path", ToolController, :file
    # The whole package, every file at its path: rebuilt from the stored
    # files, since the uploaded archive isn't kept.
    get "/tools/:slug/package.tar.gz", ToolController, :package
    get "/me/drive", MeController, :drive
    post "/notes", NoteController, :create

    # The caller's own OpenRouter key: what every AI feature spends for them.
    put "/me/ai-key", MeController, :put_ai_key
    post "/me/ai-key", MeController, :put_ai_key
    delete "/me/ai-key", MeController, :delete_ai_key
    put "/me/display", MeController, :put_display
    post "/me/display", MeController, :put_display
    put "/me/ai-provider", MeController, :put_ai_provider
    post "/me/ai-provider", MeController, :put_ai_provider
    get "/me/ai-models", MeController, :ai_models

    # Semantic search across everything the token's owner can read, and the
    # assistant that searches on its own (see `Slipdock.Search`).
    get "/search", SearchController, :search
    get "/search/status", SearchController, :status
    post "/ask", SearchController, :ask
    get "/ask", SearchController, :ask

    # The caller's own saved queries — the questions they keep asking.
    get "/saved-queries", SearchController, :saved
    post "/saved-queries", SearchController, :save
    delete "/saved-queries/:id", SearchController, :unsave
    delete "/saved-queries", SearchController, :unsave

    # The caller's own passkeys (#828): listed and removed here, added only in
    # a browser, where the authenticator is.
    get "/me/passkeys", PasskeyController, :index
    delete "/me/passkeys/:id", PasskeyController, :delete

    # The signed-in user's own favourites (see `Slipdock.Favourites`).
    get "/favourites", FavouriteController, :index
    post "/favourites", FavouriteController, :create
    delete "/favourites/:kind/:id", FavouriteController, :delete
    # The caller's own card views (#2031, see `Slipdock.CardViews`): the
    # named ones, each level's, and the view that applies.
    get "/card-views", CardViewController, :index
    post "/card-views", CardViewController, :create
    get "/card-views/applied", CardViewController, :applied
    get "/card-views/level", CardViewController, :show_level
    put "/card-views/level", CardViewController, :update_level
    patch "/card-views/level", CardViewController, :update_level
    delete "/card-views/level", CardViewController, :clear_level
    get "/card-views/:id", CardViewController, :show
    patch "/card-views/:id", CardViewController, :update
    delete "/card-views/:id", CardViewController, :delete
    # The skills registry (#2072, see `Slipdock.SkillRegistry`): the caller's
    # sources and the seeds, an entry in full, the Playbook stages naming a
    # skill, and a board's skills enabled, re-pinned and disabled by a writer.
    get "/skill-sources", SkillRegistryController, :index
    post "/skill-sources", SkillRegistryController, :create
    get "/skill-sources/:id", SkillRegistryController, :show
    post "/skill-sources/:id/refresh", SkillRegistryController, :refresh
    delete "/skill-sources/:id", SkillRegistryController, :delete
    get "/skill-entries/:id", SkillRegistryController, :entry
    get "/skill-stages", SkillRegistryController, :stages
    # What the board's agents get (#2063): its enabled skills, pinned text and all.
    get "/boards/:board/skills", SkillRegistryController, :board
    post "/boards/:board/skills", SkillRegistryController, :enable
    patch "/boards/:board/skills/:name", SkillRegistryController, :repin
    delete "/boards/:board/skills/:name", SkillRegistryController, :disable
    # The caller's own board hotkeys, Ctrl+Shift+a digit (see `Slipdock.Hotkeys`).
    get "/hotkeys", HotkeyController, :index
    put "/boards/:board/hotkey", HotkeyController, :update
    # The caller's own header links, left of quick add (see `Slipdock.HeaderLinks`).
    get "/header-links", HeaderLinkController, :index
    post "/header-links", HeaderLinkController, :create
    patch "/header-links/:id", HeaderLinkController, :update
    delete "/header-links/:id", HeaderLinkController, :delete
    get "/templates", TemplateController, :index
    post "/templates", TemplateController, :create
    get "/templates/:id", TemplateController, :show
    patch "/templates/:id", TemplateController, :update
    delete "/templates/:id", TemplateController, :delete

    # Board trees out as one JSON document, and back in again. A read-only
    # token can take an export and cannot push one in — the pipeline already
    # draws that line, so there is no scope of its own here.
    get "/export", PortableController, :export
    post "/import", PortableController, :import

    get "/boards", BoardController, :index
    post "/boards", BoardController, :create
    # The caller's own order for the board index.
    post "/boards/order", BoardController, :order
    # The tour board a first sign-in builds, on demand (see `Slipdock.Onboarding`).
    post "/boards/welcome", BoardController, :welcome
    get "/boards/:board", BoardController, :show
    patch "/boards/:board", BoardController, :update
    delete "/boards/:board", BoardController, :delete
    post "/boards/:board/archive", BoardController, :archive
    post "/boards/:board/restore", BoardController, :restore
    get "/boards/:board/activity", BoardController, :activity
    get "/boards/:board/pulse", BoardController, :pulse
    get "/boards/:board/handbook", BoardController, :handbook
    get "/boards/:board/dora", BoardController, :dora
    get "/boards/:board/flow", BoardController, :flow
    get "/boards/:board/runner_stats", BoardController, :runner_stats
    get "/boards/:board/quality", BoardController, :quality
    post "/boards/:board/deploy-token", BoardController, :deploy_token
    get "/boards/:board/deployments/setup", BoardController, :deploy_setup
    post "/boards/:board/deployments/setup", BoardController, :deploy_setup
    delete "/boards/:board/deploy-token", BoardController, :revoke_deploy_token
    get "/boards/:board/recurring", RecurrenceController, :index
    get "/boards/:board/swimlanes", BoardController, :swimlanes
    get "/boards/:board/views", BoardController, :views
    post "/boards/:board/views", BoardController, :create_view
    get "/boards/:board/views/:id", BoardController, :view
    patch "/boards/:board/views/:id", BoardController, :update_view
    delete "/boards/:board/views/:id", BoardController, :delete_view
    get "/boards/:board/columns", BoardController, :columns
    post "/boards/:board/columns", BoardController, :create_column
    patch "/boards/:board/columns/:id", BoardController, :update_column
    delete "/boards/:board/columns/:id", BoardController, :delete_column
    delete "/boards/:board/columns/:id/recursive", BoardController, :recursive_delete
    get "/boards/:board/fields", BoardController, :fields
    post "/boards/:board/fields", BoardController, :create_field
    patch "/boards/:board/fields/:id", BoardController, :update_field
    delete "/boards/:board/fields/:id", BoardController, :delete_field
    post "/boards/:board/presets/:key", BoardController, :install_preset
    get "/boards/:board/milestones", BoardController, :milestones
    post "/boards/:board/milestones", BoardController, :create_milestone
    delete "/boards/:board/milestones/:id", BoardController, :delete_milestone
    # Automation rules (owner only) and the alerts they raise.
    get "/automations/vocabulary", AutomationController, :vocabulary
    get "/automations/presets", AutomationController, :presets
    get "/alerts", AutomationController, :alerts
    delete "/alerts", AutomationController, :dismiss_all
    delete "/alerts/:id", AutomationController, :dismiss
    get "/boards/:board/automations", AutomationController, :index
    post "/boards/:board/automations", AutomationController, :create
    get "/boards/:board/automations/callbacks", AutomationController, :callbacks
    get "/boards/:board/automations/:id", AutomationController, :show
    patch "/boards/:board/automations/:id", AutomationController, :update
    delete "/boards/:board/automations/:id", AutomationController, :delete
    post "/boards/:board/automations/:id/run", AutomationController, :run
    # Runners on the user's own machines and the jobs rules send them.
    get "/boards/:board/runners", JobController, :runners
    post "/boards/:board/runners", JobController, :create_runner
    post "/boards/:board/runners/setup", JobController, :setup
    get "/boards/:board/runners/:id", JobController, :show_runner
    get "/boards/:board/runners/:id/setup", JobController, :runner_setup
    get "/boards/:board/runners/:id/hook-prompt", JobController, :hook_prompt
    put "/boards/:board/runners/:id/setup", JobController, :update_setup
    post "/boards/:board/runners/:id/token", JobController, :rotate_token
    delete "/boards/:board/runners/:id", JobController, :delete_runner
    get "/boards/:board/jobs", JobController, :index
    get "/boards/:board/release", ReleaseController, :show
    post "/boards/:board/release", ReleaseController, :create
    delete "/boards/:board/release/hold", ReleaseController, :lift_hold
    get "/boards/:board/pause", JobController, :pauses
    post "/boards/:board/pause", JobController, :pause
    delete "/boards/:board/pause", JobController, :resume
    post "/boards/:board/jobs/claim", JobController, :claim
    get "/cards/:id/jobs", JobController, :card_jobs
    get "/jobs/:id", JobController, :show
    get "/jobs/:id/transcript", JobController, :transcript
    get "/jobs/:id/log", JobController, :log
    post "/jobs/:id/keep", JobController, :keep
    post "/jobs/:id/cancel", JobController, :cancel
    post "/jobs/:id/progress", JobController, :progress
    post "/jobs/:id/finish", JobController, :finish

    get "/boards/:board/tags", BoardController, :tags
    post "/boards/:board/tags", BoardController, :create_tag
    delete "/boards/:board/tags/:id", BoardController, :delete_tag
    get "/boards/:board/cards", CardController, :index
    post "/boards/:board/cards", CardController, :create
    get "/boards/:board/sprints/next", SprintController, :next
    get "/boards/:board/sprints/velocity", SprintController, :velocity
    get "/boards/:board/sprints/sources", SprintController, :sources
    put "/boards/:board/sprints/sources", SprintController, :put_sources
    post "/boards/:board/sprints", SprintController, :create

    # The caller's vault: every board they own as one tree of files (W-2201).
    # `/wiki/...` below is its address now; these stay so a client built
    # against them keeps working until it moves.
    get "/vaults", VaultController, :index
    get "/vaults/:id", VaultController, :show
    patch "/vaults/:id", VaultController, :update
    get "/vaults/:id/locate", VaultController, :locate
    get "/vaults/:id/resolve", VaultController, :resolve
    get "/vaults/:id/wanted", VaultController, :wanted
    get "/vaults/:id/changes", VaultController, :changes
    # `slipdock sync`: the vault as a folder of files (W-103 R2).
    get "/vaults/:id/sync", VaultSyncController, :index
    get "/vaults/:id/sync/pages/:page", VaultSyncController, :show_page
    put "/vaults/:id/sync/pages", VaultSyncController, :put_page
    put "/vaults/:id/sync/pages/:page", VaultSyncController, :put_page
    delete "/vaults/:id/sync/pages/:page", VaultSyncController, :delete_page
    get "/vaults/:id/sync/files/:file", VaultSyncController, :show_file
    post "/vaults/:id/sync/files", VaultSyncController, :post_file
    post "/vaults/:id/sync/files/:file_id", VaultSyncController, :post_file
    patch "/vaults/:id/sync/files/:file_id", VaultSyncController, :patch_file
    delete "/vaults/:id/sync/files/:file_id", VaultSyncController, :delete_file
    # The board's wiki (see `Slipdock.Wiki`). `:id` takes a numeric id, a page
    # code like W-31, or board-code/slug.
    get "/pages/resolve", PageController, :resolve
    # The grammar a ```kanban block is written in, and a way to try one.
    get "/pages/query-vocabulary", PageController, :query_vocabulary
    post "/pages/query", PageController, :check_query
    get "/boards/:board/pages", PageController, :index
    post "/boards/:board/pages", PageController, :create
    # Folders: where pages are filed, nested to any depth. `/wiki` is the
    # caller's one wiki (W-2201): what it is, and every board the reader can
    # open, folders and all.
    get "/wiki", PageController, :wiki
    get "/boards/:board/folders", PageController, :folders
    # The wiki's files that are not pages (#1156): a list, and one by its
    # path, such as the `Tool/…` files a Tool's install puts there.
    get "/boards/:board/files", WikiFileController, :index
    get "/boards/:board/files/*path", WikiFileController, :show
    # One level of the tree at a time, never a body (W-103 R11.1).
    get "/boards/:board/tree", PageController, :tree
    patch "/boards/:board/tree", PageController, :set_tree_sort
    post "/boards/:board/folders", PageController, :create_folder
    get "/folders/:id", PageController, :show_folder
    # Sharing a page or folder, and what has been shared with you (#820).
    get "/pages/:page_id/grants", GrantController, :index
    post "/pages/:page_id/grants", GrantController, :create
    delete "/pages/:page_id/grants", GrantController, :delete
    get "/folders/:folder_id/grants", GrantController, :index
    post "/folders/:folder_id/grants", GrantController, :create
    delete "/folders/:folder_id/grants", GrantController, :delete
    get "/shared", GrantController, :shared
    patch "/folders/:id", PageController, :update_folder
    # Inside a folder by its id: how somebody it was shared with adds to it.
    post "/folders/:id/pages", PageController, :create_in_folder
    post "/folders/:id/folders", PageController, :create_folder_in
    delete "/folders/:id", PageController, :delete_folder
    # The same two by any handle, with the board to read it against: a path
    # of names is what somebody on the command line has.
    get "/boards/:board/folders/*id", PageController, :show_folder
    patch "/boards/:board/folders/*id", PageController, :update_folder
    delete "/boards/:board/folders/*id", PageController, :delete_folder
    # A folder's Organise… (#791): by date, tag, flattening or the AI's
    # suggestions; `dry_run` says where things would go.
    post "/boards/:board/organise", PageController, :organise_folder
    post "/pages/:id/folder", PageController, :file
    get "/pages/:id", PageController, :show
    patch "/pages/:id", PageController, :update
    delete "/pages/:id", PageController, :delete
    post "/pages/:id/restore", PageController, :restore
    post "/pages/:id/move", PageController, :move
    get "/pages/:id/render", PageController, :render_page
    # A meeting page's audio, for a client holding a token (#1562).
    get "/pages/:id/recording", RecordingController, :show
    get "/pages/:id/sections", PageController, :sections
    get "/pages/:id/section/*path", PageController, :read_section
    put "/pages/:id/section/*path", PageController, :replace_section
    post "/pages/:id/section/*path", PageController, :append_section
    post "/pages/:id/append", PageController, :append
    get "/pages/:id/links", PageController, :links
    post "/pages/:id/links", PageController, :pin
    get "/boards/:board/pages/wanted", PageController, :wanted
    # The quick switcher's matching, for a shell: title, alias or vault path.
    get "/boards/:board/pages/switch", PageController, :switch
    get "/boards/:board/pages/tags", PageController, :note_tags
    post "/boards/:board/pages/from-template", PageController, :from_template
    get "/cards/:id/pages", PageController, :for_card
    post "/cards/:id/pages", PageController, :write_up
    post "/pages/:id/cards", PageController, :make_card
    post "/pages/:id/ai", PageController, :ai
    get "/pages/:id/revisions", PageController, :revisions
    post "/pages/:id/revisions/purge", PageController, :purge_revisions
    get "/pages/:id/revisions/:rev", PageController, :revision
    post "/pages/:id/revert", PageController, :revert
    post "/pages/:id/publish", PageController, :publish
    # A page can sit in one of the board's lists and be dragged like a card.
    post "/pages/:id/place", PageController, :place
    delete "/pages/:id/place", PageController, :unplace
    post "/pages/:id/comments", PageController, :add_comment
    post "/pages/:id/checklist", PageController, :add_checklist_item
    post "/pages/:id/status", PageController, :add_status_update
    post "/pages/:id/urls", PageController, :add_url
    delete "/pages/:id/urls/:url_id", PageController, :remove_url
    get "/pages/:id/attachments", PageController, :attachments
    post "/pages/:id/attachments", PageController, :add_attachment
    delete "/pages/:id/attachments/:attachment_id", PageController, :remove_attachment
    post "/pages/:id/vote", PageController, :vote
    get "/boards/:board/pages/export", PageController, :export
    post "/boards/:board/pages/import", PageController, :import_files

    get "/cards/:id", CardController, :show
    patch "/cards/:id", CardController, :update
    delete "/cards/:id", CardController, :delete
    post "/cards/:id/move", CardController, :move
    post "/cards/:id/archive", CardController, :archive
    post "/cards/:id/restore", CardController, :restore
    post "/cards/:id/copy", CardController, :copy
    post "/cards/:id/incident-of", CardController, :incident_of
    delete "/cards/:id/incident-of", CardController, :incident_of
    get "/cards/:id/recurrence", RecurrenceController, :show
    put "/cards/:id/recurrence", RecurrenceController, :update
    delete "/cards/:id/recurrence", RecurrenceController, :delete
    post "/cards/:id/recurrence/skip", RecurrenceController, :skip
    get "/boards/:board/overseer", OverseerController, :show
    patch "/boards/:board/overseer", OverseerController, :update
    get "/boards/:board/garden", GardenController, :index
    post "/boards/:board/garden", GardenController, :create
    patch "/boards/:board/garden/settings", GardenController, :settings
    post "/boards/:board/garden/proposals", GardenController, :propose
    post "/garden/suggestions/:id/apply", GardenController, :apply
    post "/garden/suggestions/:id/dismiss", GardenController, :dismiss
    post "/garden/suggestions/:id/undo", GardenController, :undo
    get "/boards/:board/health", HealthController, :index
    get "/boards/:board/now", NowController, :show
    post "/boards/:board/health", HealthController, :create
    patch "/boards/:board/health/settings", HealthController, :settings
    get "/boards/:board/findings", FindingController, :index
    get "/boards/:board/ledger", LedgerController, :index
    patch "/findings/:id", FindingController, :update
    post "/cards/:id/snooze", SnoozeController, :create
    delete "/cards/:id/snooze", SnoozeController, :delete
    post "/cards/:id/checklist", CardController, :add_checklist_item
    post "/cards/:id/comments", CardController, :add_comment
    get "/cards/:id/handoff", CardController, :handoff
    get "/cards/:id/timeline", CardController, :timeline
    post "/cards/:id/handoff", CardController, :leave_handoff
    delete "/cards/:id/handoff", CardController, :delete_handoff
    post "/cards/:id/wait", CardController, :open_wait
    post "/cards/:id/verify", CardController, :verify
    delete "/cards/:id/wait", CardController, :withdraw_wait
    post "/cards/:id/wait/answer", CardController, :answer_wait
    get "/cards/:id/waits", CardController, :waits
    post "/cards/:id/vote", CardController, :vote
    post "/cards/:id/timer", CardController, :timer
    post "/cards/:id/links", CardController, :add_link
    delete "/cards/:id/links/:link_id", CardController, :remove_link
    post "/cards/:id/urls", CardController, :add_url
    delete "/cards/:id/urls/:url_id", CardController, :remove_url
    # Files, sent as the multipart field `file` (see `SlipdockWeb.API.Uploads`).
    # One file by its attachment id, whatever it hangs off (#920): its
    # details, and its bytes for `slipdock download`.
    get "/attachments/:id", AttachmentController, :show
    get "/attachments/:id/file", AttachmentController, :file
    get "/attachments/:id/text", AttachmentController, :text
    get "/cards/:id/attachments", CardController, :attachments
    post "/cards/:id/attachments", CardController, :add_attachment
    patch "/cards/:id/attachments/:attachment_id", CardController, :update_attachment

    post "/cards/:id/attachments/:attachment_id/transcribe",
         CardController,
         :transcribe_attachment

    post "/cards/:id/attachments/:attachment_id/read-text",
         CardController,
         :read_attachment_text

    delete "/cards/:id/attachments/:attachment_id", CardController, :remove_attachment
    post "/cards/:id/status", CardController, :add_status_update
    post "/cards/:id/dependencies", CardController, :add_dependency
    post "/cards/:id/subboard", CardController, :create_sub_board
    post "/cards/:id/sprint", SprintController, :add
    get "/cards/:id/burndown", SprintController, :burndown
    get "/cards/:id/sprint/plan", SprintController, :plan
    delete "/cards/:id/subboard", CardController, :delete_sub_board
    delete "/cards/:id/dependencies/:other_id", CardController, :remove_dependency
    post "/checklist/:item_id/toggle", CardController, :toggle_checklist_item
    post "/checklist/:item_id/move", CardController, :move_checklist_item
    delete "/checklist/:item_id", CardController, :delete_checklist_item
    delete "/comments/:comment_id", CardController, :delete_comment
  end
end
