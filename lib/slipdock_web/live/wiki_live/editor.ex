defmodule SlipdockWeb.WikiLive.Editor do
  @moduledoc """
  The wiki page editor (`WikiLive.Index`): the Markdown pane, its
  preview, the encryption menu and the list of unsaved autosaves.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.FolderPicker

  import SlipdockWeb.SlipdockComponents,
    only: [timestamp: 1]

  import SlipdockWeb.WikiLive.Format
  import SlipdockWeb.WikiLive.Modals
  import SlipdockWeb.WikiLive.PageView
  alias Slipdock.Wiki.{Autosave, Autosaves}

  attr :class, :string, default: nil, doc: "the buttons' classes, drawn in a row"
  attr :item, :boolean, default: false, doc: "draw them as menu items instead"

  # The three Meld Encrypt actions (`assets/js/meld_editor.js` handles any
  # `[data-meld-action]` click inside `#meld-tools`), in the editor's row or
  # its ⋯ menu (#1744).
  defp meld_actions(assigns) do
    assigns =
      assign(assigns, :actions, [
        {"encrypt", "hero-lock-closed", "Encrypt",
         "Encrypt the selected text, or type a new secret to add encrypted"},
        {"whole", "hero-document-text", "Encrypt whole note",
         "Encrypt the whole note into one block"},
        {"edit", "hero-lock-open", "Decrypt to edit",
         "Decrypt the block the cursor is in, to change it or remove its encryption"}
      ])

    ~H"""
    <%= for {action, icon, label, title} <- @actions do %>
      <li :if={@item}>
        <button type="button" data-meld-action={action} title={title}>
          <.icon name={icon} class="size-4" /> {label}
        </button>
      </li>
      <button :if={!@item} type="button" data-meld-action={action} class={@class} title={title}>
        <.icon name={icon} class="size-4" /> {label}
      </button>
    <% end %>
    """
  end

  attr :form, :any, required: true
  attr :page, :any, default: nil
  attr :board, :any, required: true
  attr :preview, :string, default: ""
  attr :show_preview, :boolean, default: false
  attr :conflict, :any, default: nil
  attr :base_hash, :string, default: nil
  attr :uploads, :any, required: true
  attr :column, :any, default: nil, doc: "the list a new page will be placed in"
  attr :outline, :list, default: [], doc: "the board's folders, for the Folder picker"
  attr :autosaved?, :boolean, default: false
  attr :restored_from, :any, default: nil, doc: "when the restored auto-save was written"
  attr :page_tools, :any, default: nil, doc: "the AI tools button: its pressed state, or nil"

  # Not a hole: @preview is MDEx output, sanitised (ammonia), with the CSP behind it.
  # sobelow_skip ["XSS.Raw"]
  def editor(assigns) do
    assigns =
      assign(assigns, :encrypted?, Slipdock.Wiki.Meld.encrypted?(assigns.form[:body].value))

    ~H"""
    <.form for={@form} id="page-form" phx-change="validate" phx-submit="save" class="space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="min-w-0">
          <h1 class="page-title">
            {if @page, do: "Editing #{@page.title}", else: "New page"}
          </h1>
          <%!-- Started from the foot of a list: say so, since the page will
                appear there as a card the moment it is saved. --%>
          <p :if={@column} class="mt-0.5 flex items-center gap-1.5 text-xs text-base-content/60">
            <.icon name="hero-view-columns" class="size-3.5" />
            It will sit on the board in <span class="font-medium">{@column.name}</span>.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <%!-- Meld Encrypt (W-103 R6.2, R6.4): secrets are typed into the
                passphrase dialog, outside this form, and only ciphertext
                comes into the body. Ignored by LiveView, since the hook
                keeps the purge choice and its notes. Few pages are
                encrypted, so on an ordinary page the actions wait in the
                editor's ⋯ menu; on one that already holds a secret they
                stand in the row, where they matter (#1744). --%>
          <div
            id="meld-tools"
            phx-hook="MeldEditor"
            phx-update="ignore"
            data-textarea="page_body"
            data-encrypted={to_string(@encrypted?)}
            class="flex flex-wrap items-center gap-1 text-xs"
          >
            <span data-meld-note class="text-warning" hidden></span>
            <input type="hidden" name="purge_revisions" value="" data-meld-purge />
            <%= if @encrypted? do %>
              <.meld_actions class="btn btn-ghost btn-sm" />
            <% else %>
              <div class="dropdown dropdown-end">
                <div
                  id="editor-menu"
                  tabindex="0"
                  role="button"
                  class="btn btn-ghost btn-sm btn-square"
                  title="More: encryption"
                  aria-label="More editor actions"
                >
                  <.icon name="hero-ellipsis-horizontal" class="size-5" />
                </div>
                <ul
                  id="editor-menu-items"
                  tabindex="0"
                  class="menu dropdown-content z-40 mt-1 w-64 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
                >
                  <.meld_actions item />
                </ul>
              </div>
            <% end %>
          </div>
          <%!-- Only where the preview can show: below lg it never does. A
                pressed toggle is a ghost button, active (#1744). --%>
          <button
            type="button"
            id="toggle-preview"
            phx-hook="EditorPrefs"
            phx-click="toggle_preview"
            aria-pressed={to_string(@show_preview)}
            title={if @show_preview, do: "Hide the preview", else: "Show the preview beside it"}
            class={["btn btn-ghost btn-sm hidden lg:inline-flex", @show_preview && "btn-active"]}
          >
            <.icon name={if @show_preview, do: "hero-eye", else: "hero-eye-slash"} class="size-4" />
            Preview
          </button>
          <.page_tools_toggle pressed={@page_tools} />
          <span
            :if={@autosaved?}
            id="autosave-status"
            role="status"
            class="text-xs text-base-content/50"
          >
            Auto-saved
          </span>
          <button id="cancel-edit" type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button id="save-page" type="submit" class="btn btn-primary btn-sm">Save</button>
        </div>
      </div>

      <div
        :if={@restored_from}
        id="autosave-restored"
        class="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-sky-500/40 bg-sky-500/10 px-4 py-2 text-sm"
      >
        <span>
          Restored your unsaved work from {SlipdockWeb.SlipdockComponents.relative_time(
            as_datetime(@restored_from)
          )}.
        </span>
        <button type="button" phx-click="discard_autosave" class="btn btn-ghost btn-xs">
          Discard it
        </button>
      </div>

      <div
        :if={@conflict}
        class="rounded-xl border border-rose-500/40 bg-rose-500/10 p-4 text-sm"
      >
        <div class="flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-rose-600" />
          <div class="min-w-0 flex-1">
            <p class="font-medium">
              This page changed while you were writing. Nothing has been overwritten.
            </p>
            <p class="mt-1 text-base-content/70">
              Below is the page as it now stands. Merge what you need into your text, then save
              again.
            </p>
            <pre
              class="kanban-scroll mt-3 max-h-64 overflow-auto rounded-lg bg-base-100 p-3 text-xs"
              phx-no-curly-interpolation
            ><%= @conflict.body %></pre>
          </div>
          <button type="button" phx-click="dismiss_conflict" class="btn btn-ghost btn-xs btn-square">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>

      <input :if={@base_hash} type="hidden" name="page[base_hash]" value={@base_hash} />

      <%!-- A new page has an empty title and that is what you came to type;
            an edit has one already, and stealing the cursor from the body
            would be wrong. --%>
      <.input
        field={@form[:title]}
        type="text"
        label="Title"
        required
        phx-hook={is_nil(@page) && "Focus"}
        id={is_nil(@page) && "new-page-title"}
      />
      <.input
        field={@form[:summary]}
        type="text"
        label="Summary"
        placeholder="One line, shown in listings and search"
      />

      <div class={["grid gap-4", @show_preview && "lg:grid-cols-2"]}>
        <div id="page-body-paste" phx-hook="PasteImage" data-upload="page_image">
          <label for="page_body" class="mb-1 block text-sm font-medium">
            Body (Markdown)
            <span class="ml-1 font-normal text-base-content/50">— paste or drop an image to attach it</span>
          </label>
          <%!-- The Markdown editor (MarkdownEditor) takes over the
                textarea, which stays the form's field. Ignored by LiveView
                so a patch never resets it; keyed on the page, so opening
                another page's editor starts a new one. --%>
          <%!-- Typing [[ offers the wiki's pages to link (PageLink). --%>
          <div id="page-body-page-link" phx-hook="PageLink" data-board={@board.id}>
            <div
              id={"page-body-editor-#{(@page && @page.id) || "new"}"}
              phx-hook="MarkdownEditor"
              phx-update="ignore"
              data-editor-class="md-editor-page"
            >
              <textarea
                id="page_body"
                name="page[body]"
                rows="24"
                class="textarea field field-mono w-full leading-relaxed"
                phx-debounce="200"
              ><%= Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value) %></textarea>
            </div>
          </div>
          <.live_file_input upload={@uploads.page_image} class="hidden" />
        </div>
        <div :if={@show_preview} id="page-preview" class="hidden lg:block">
          <p class="mb-1 text-sm font-medium">Preview</p>
          <div class="wiki-prose kanban-scroll max-h-[36rem] overflow-y-auto rounded-xl border border-base-300 bg-base-100 p-4">
            {Phoenix.HTML.raw(@preview)}
          </div>
        </div>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div>
          <label for="edit-message" class="mb-1 block text-sm font-medium">
            Why this edit <span class="font-normal text-base-content/50">(optional)</span>
          </label>
          <input
            id="edit-message"
            type="text"
            name="message"
            placeholder="Recorded in the page's history"
            class="input field w-full"
          />
        </div>
        <.input
          field={@form[:status]}
          type="select"
          label="Status"
          options={[{"Published", "published"}, {"Draft — only writers can see it", "draft"}]}
        />
        <%!-- Where it is filed. Offered here so a page can be put away at the
              moment it is written, rather than written and then found again. --%>
        <.folder_picker
          id="editor-folder-picker"
          label="Folder"
          name={@form[:folder_id].name}
          selected={@form[:folder_id].value}
          outline={@outline}
        />
        <.dress_picker
          id="page-dress"
          kind={:page}
          icon_name={@form[:icon].name}
          color_name={@form[:color].name}
          icon={dress_value(@form[:icon].value)}
          color={dress_value(@form[:color].value)}
        />
      </div>
    </.form>
    """
  end

  attr :board, :any, required: true
  attr :unsaved, :list, required: true

  # Work left in the editor and never saved, to pick up or let go of (#1532).
  def unsaved_pages(assigns) do
    ~H"""
    <section
      id="unsaved-pages"
      class="mb-4 rounded-xl border border-base-300 bg-base-200/40 px-4 py-3 text-sm"
    >
      <h2 class="font-medium">Unsaved work</h2>
      <p class="text-xs text-base-content/60">
        Only you can see this. It is kept for {Autosaves.ttl_days()} days.
      </p>
      <ul class="mt-2 space-y-1">
        <li :for={autosave <- @unsaved} class="flex items-center justify-between gap-2">
          <.link
            navigate={
              if autosave.page,
                do: ~p"/boards/#{@board}/wiki/#{autosave.page.slug}/edit",
                else: ~p"/boards/#{@board}/wiki/new?autosave=#{autosave.id}"
            }
            class="link min-w-0 truncate"
          >
            {if autosave.page, do: "Editing #{autosave.page.title}", else: Autosave.title(autosave)}
          </.link>
          <span class="flex shrink-0 items-center gap-2 text-xs text-base-content/50">
            <.timestamp at={as_datetime(autosave.updated_at)} />
            <button
              type="button"
              phx-click="discard_autosave"
              phx-value-id={autosave.id}
              class="btn btn-ghost btn-xs"
            >
              Discard
            </button>
          </span>
        </li>
      </ul>
    </section>
    """
  end
end
