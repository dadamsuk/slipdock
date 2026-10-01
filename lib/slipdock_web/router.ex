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
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_api_user
    plug :require_token_write
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

    get "/login/:token", SessionController, :create
    delete "/logout", SessionController, :delete

    # Approving an agent's request to sign in. Signed-in people only, and the
    # decision is a POST with CSRF — never a GET, so a link cannot approve
    # itself when opened.
    get "/activate", DeviceActivationController, :show
    post "/activate", DeviceActivationController, :decide

    live_session :public,
      on_mount: [
        {SlipdockWeb.UserAuth, :redirect_if_user_is_authenticated},
        {SlipdockWeb.ViewportHook, :default}
      ] do
      live "/login", LoginLive.Index, :index
    end

    # Published saved views: readable by anyone with the link.
    live_session :published,
      on_mount: [
        {SlipdockWeb.UserAuth, :mount_current_user},
        {SlipdockWeb.ViewportHook, :default}
      ] do
      live "/p/:token", PublicLive.Show, :show
      # A published wiki page: the prose is current, the answers are a
      # snapshot, and nothing is followable (see `SlipdockWeb.PublicLive.Page`).
      live "/w/:token", PublicLive.Page, :show
    end
  end

  if Application.compile_env(:slipdock, :dev_routes) do
    scope "/dev" do
      pipe_through :browser
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", SlipdockWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/attachments/:id/:filename", AttachmentController, :show
    get "/boards/:id/export.csv", ExportController, :table
    # The board's wiki as a folder of Markdown: the escape hatch.
    get "/boards/:id/wiki.zip", ExportController, :wiki
    # One page as Markdown, front matter and all — the same file the zip holds.
    get "/boards/:id/wiki/:slug/page.md", ExportController, :page

    live_session :authenticated,
      on_mount: [
        {SlipdockWeb.UserAuth, :ensure_authenticated},
        {SlipdockWeb.ViewportHook, :default},
        {SlipdockWeb.AlertsHook, :default},
        {SlipdockWeb.QuickAddHook, :default},
        {SlipdockWeb.ShortcutsHook, :default}
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
      live "/account", AccountLive.Index, :index
      live "/groups", GroupLive.Index, :index
      live "/templates", TemplateLive.Index, :index
      live "/favourites", FavouriteLive.Index, :index
      # Every board's documents in one tree: boards as the top level, then
      # each board's folders and pages (see `SlipdockWeb.WikiLive.All`).
      live "/wiki", WikiLive.All, :index
      # The board's wiki: a tree of Markdown pages beside its cards.
      live "/boards/:id/wiki", WikiLive.Index, :index
      live "/boards/:id/wiki/new", WikiLive.Index, :new
      live "/boards/:id/wiki/:slug", WikiLive.Index, :show
      live "/boards/:id/wiki/:slug/edit", WikiLive.Index, :edit
      live "/boards/:id/wiki/:slug/history", WikiLive.Index, :history
      live "/boards/:id/wiki/:slug/history/:rev", WikiLive.Index, :revision
      live "/boards/:id", BoardLive.Show, :show
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
  end

  scope "/api", SlipdockWeb.API do
    pipe_through :api_guide

    get "/guide", GuideController, :show

    # The agent skills this app ships (see `Slipdock.Skills`). Like the guide,
    # they need no token: they say how to call the API, not what is on it.
    get "/skills", SkillController, :index
    get "/skills/:name", SkillController, :show
    get "/skills/:name/*file", SkillController, :show
  end

  scope "/api", SlipdockWeb.API do
    pipe_through :api

    get "/me", MeController, :show

    # The caller's own OpenRouter key: what every AI feature spends for them.
    put "/me/ai-key", MeController, :put_ai_key
    post "/me/ai-key", MeController, :put_ai_key
    delete "/me/ai-key", MeController, :delete_ai_key

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

    # The signed-in user's own favourites (see `Slipdock.Favourites`).
    get "/favourites", FavouriteController, :index
    post "/favourites", FavouriteController, :create
    delete "/favourites/:kind/:id", FavouriteController, :delete
    get "/templates", TemplateController, :index
    post "/templates", TemplateController, :create
    get "/templates/:id", TemplateController, :show
    patch "/templates/:id", TemplateController, :update
    delete "/templates/:id", TemplateController, :delete

    get "/boards", BoardController, :index
    post "/boards", BoardController, :create
    # The caller's own order for the board index.
    post "/boards/order", BoardController, :order
    get "/boards/:board", BoardController, :show
    patch "/boards/:board", BoardController, :update
    delete "/boards/:board", BoardController, :delete
    post "/boards/:board/archive", BoardController, :archive
    post "/boards/:board/restore", BoardController, :restore
    get "/boards/:board/activity", BoardController, :activity
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
    get "/alerts", AutomationController, :alerts
    delete "/alerts", AutomationController, :dismiss_all
    delete "/alerts/:id", AutomationController, :dismiss
    get "/boards/:board/automations", AutomationController, :index
    post "/boards/:board/automations", AutomationController, :create
    get "/boards/:board/automations/:id", AutomationController, :show
    patch "/boards/:board/automations/:id", AutomationController, :update
    delete "/boards/:board/automations/:id", AutomationController, :delete
    post "/boards/:board/automations/:id/run", AutomationController, :run

    get "/boards/:board/tags", BoardController, :tags
    post "/boards/:board/tags", BoardController, :create_tag
    delete "/boards/:board/tags/:id", BoardController, :delete_tag
    get "/boards/:board/cards", CardController, :index
    post "/boards/:board/cards", CardController, :create

    # The board's wiki (see `Slipdock.Wiki`). `:id` takes a numeric id, a page
    # code like W-31, or board-code/slug.
    get "/pages/resolve", PageController, :resolve
    # The grammar a ```kanban block is written in, and a way to try one.
    get "/pages/query-vocabulary", PageController, :query_vocabulary
    post "/pages/query", PageController, :check_query
    get "/boards/:board/pages", PageController, :index
    post "/boards/:board/pages", PageController, :create
    # Folders: where pages are filed, nested to any depth. `/wiki` is every
    # board the reader can open, folders and all — the Wiki view's own call.
    get "/wiki", PageController, :wiki
    get "/boards/:board/folders", PageController, :folders
    post "/boards/:board/folders", PageController, :create_folder
    patch "/folders/:id", PageController, :update_folder
    delete "/folders/:id", PageController, :delete_folder
    # The same two by any handle, with the board to read it against: a path
    # of names is what somebody on the command line has.
    patch "/boards/:board/folders/*id", PageController, :update_folder
    delete "/boards/:board/folders/*id", PageController, :delete_folder
    post "/pages/:id/folder", PageController, :file
    get "/pages/:id", PageController, :show
    patch "/pages/:id", PageController, :update
    delete "/pages/:id", PageController, :delete
    post "/pages/:id/restore", PageController, :restore
    post "/pages/:id/move", PageController, :move
    get "/pages/:id/render", PageController, :render_page
    get "/pages/:id/sections", PageController, :sections
    get "/pages/:id/section/*path", PageController, :read_section
    put "/pages/:id/section/*path", PageController, :replace_section
    post "/pages/:id/section/*path", PageController, :append_section
    post "/pages/:id/append", PageController, :append
    get "/pages/:id/links", PageController, :links
    post "/pages/:id/links", PageController, :pin
    get "/boards/:board/pages/wanted", PageController, :wanted
    post "/boards/:board/pages/from-template", PageController, :from_template
    get "/cards/:id/pages", PageController, :for_card
    post "/cards/:id/pages", PageController, :write_up
    post "/pages/:id/cards", PageController, :make_card
    get "/pages/:id/revisions", PageController, :revisions
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
    post "/pages/:id/vote", PageController, :vote
    get "/boards/:board/pages/export", PageController, :export
    post "/boards/:board/pages/import", PageController, :import_files

    get "/cards/:id", CardController, :show
    patch "/cards/:id", CardController, :update
    delete "/cards/:id", CardController, :delete
    post "/cards/:id/move", CardController, :move
    post "/cards/:id/archive", CardController, :archive
    post "/cards/:id/restore", CardController, :restore
    post "/cards/:id/checklist", CardController, :add_checklist_item
    post "/cards/:id/comments", CardController, :add_comment
    post "/cards/:id/vote", CardController, :vote
    post "/cards/:id/links", CardController, :add_link
    delete "/cards/:id/links/:link_id", CardController, :remove_link
    post "/cards/:id/urls", CardController, :add_url
    delete "/cards/:id/urls/:url_id", CardController, :remove_url
    post "/cards/:id/status", CardController, :add_status_update
    post "/cards/:id/dependencies", CardController, :add_dependency
    post "/cards/:id/subboard", CardController, :create_sub_board
    delete "/cards/:id/subboard", CardController, :delete_sub_board
    delete "/cards/:id/dependencies/:other_id", CardController, :remove_dependency
    post "/checklist/:item_id/toggle", CardController, :toggle_checklist_item
    delete "/checklist/:item_id", CardController, :delete_checklist_item
    delete "/comments/:comment_id", CardController, :delete_comment
  end
end
