# Agents working on Slipdock

Slipdock is a Phoenix 1.8 / LiveView application (`Slipdock` for the domain,
`SlipdockWeb` for the web layer), with a CLI of its own in `cli/` and a Go
runner daemon in `daemon/`. These are the house rules for an agent writing code
in it. How a card is worked, tested and shipped is in `CLAUDE.md`.

## Project guidelines

- **Project handbook:** W-1943 (Handbook/Index) on the `slipdock` board — read the sections a card needs before building (`slipdock card` lists them), and update them before closing it, with a `Handbook:` line in the closing comment. The wiki is the source of truth; don't copy it into the repo.
- **Before you push, run `mix pre_push`** and fix what it finds: it runs what CI's static checks and build do, in CI's order (`CLAUDE.md` §Before you push). Run the tests you added or changed beside it; the pull request's CI runs the whole suite (or, for a change to docs, skills, `*.md`, `cli/` or `daemon/` alone, the repo checks in its place) but no static checks, so `mix pre_push` is where a change meets them first.
- Use the included `:req` (`Req`) library for HTTP requests; **avoid** `:httpoison`, `:tesla` and `:httpc`. Don't add a dependency the card doesn't ask for.
- How the UI looks and behaves (design tokens, buttons, controls, dates, fonts) is in the handbook's UX & UI page (W-1946), and the source-convention tests in `test/repo_checks.txt` hold `lib/` to it.

### Phoenix v1.8 guidelines

- Begin a LiveView template with `<Layouts.app flash={@flash} ...>` (`SlipdockWeb.Layouts`, aliased in `lib/slipdock_web.ex`), which wraps all inner content
- `<.flash_group>` lives in `SlipdockWeb.Layouts`; don't call it outside `layouts.ex`
- Use the `<.icon name="hero-x-mark" class="size-5"/>` component from `core_components.ex` for icons, **never** `Heroicons` modules or similar
- Use the imported `<.input>` component for form inputs. If you give it a `class`, no default classes are inherited, so your classes must style the input fully

### JS and CSS guidelines

- Style with Tailwind CSS v4 classes and the daisyUI theme in `assets/css/app.css` (the brand palette; `test/slipdock_web/design_tokens_test.exs` checks its contrast). There is no `tailwind.config.js`: sources are declared with `@source` in `app.css`
- **Never** use `@apply` when writing raw CSS
- Vendored scripts (`assets/vendor/`) are imported into `app.js`; don't reference an external script `src` or stylesheet `href` in the layouts
- **Never write inline `<script>custom js</script>` tags within templates**: use a colocated hook (below)

<!-- usage-rules-start -->

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax** (`mylist[i]` is invalid): use `Enum.at`, pattern matching or `List`
- Variables are immutable but can be rebound, so bind the result of a block expression (`if`, `case`, `cond`) rather than rebinding inside it:

      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file: it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs: access the fields directly (`my_struct.field`), or use `Ecto.Changeset.get_field/2` for changesets
- The standard library's `Time`, `Date`, `DateTime` and `Calendar` cover date and time; don't add a dependency for them
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names end in a question mark and don't start with `is_`; names like `is_thing` are for guards
- OTP primitives like `DynamicSupervisor` and `Registry` need names in the child spec, such as `{DynamicSupervisor, name: Slipdock.MyDynamicSup}`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure, usually with `timeout: :infinity`

## Mix guidelines

- Read the docs and options before using tasks (`mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- Only one `mix test` run uses a test database at a time: a second run waits, saying so on stderr. To run alongside another session instead, give yours its own database with `MIX_TEST_PARTITION=2 mix test` (any number)
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
- Generate migrations with `mix ecto.gen.migration migration_name_using_underscores`, so the timestamp and conventions are right

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests (`test/slipdock/no_sleep_test.exs` checks the first)
  - To wait for a process to finish, use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - To synchronize before the next call, use `_ = :sys.get_state/1` so the process has handled prior messages
- A process that calls `Ecto.Adapters.SQL.Sandbox.start_owner!/2` itself must `stop_owner/1` it: the owner isn't linked to it, and a forgotten one keeps its transaction (and its board's code and shortcut) open for the rest of the run, so a later test that is handed the same key waits on it until the query times out
- In an async test, don't assert a board code or shortcut derived from a name: derivation steps around keys other running tests hold (`Slipdock.BoardKeyClaims`), so the value depends on what else is running. Set the code by hand (one no other async module uses) or make the module sync

## Phoenix guidelines

- Router `scope` blocks carry an alias that prefixes every route within them, so you **never** need your own `alias` for route definitions: in `scope "/", SlipdockWeb do`, `live "/boards/:id", BoardLive.Show, :show` points at `SlipdockWeb.BoardLive.Show`
- `Phoenix.View` is not used; don't add it

## Ecto guidelines

- **Always** preload associations in queries when they'll be accessed in templates
- `Ecto.Schema` fields use the `:string` type for `:text` columns too: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **does not support `:allow_nil`**: validations only run on a non-nil change anyway
- Use `Ecto.Changeset.get_field(changeset, :field)` to read changeset fields
- Fields set programmatically, such as `user_id`, must not be listed in `cast` calls: set them explicitly when building the struct

## HEEx guidelines

- Templates use `~H` or `.html.heex` files, **never** `~E`
- Build forms with `Phoenix.Component.form/1` and `inputs_for/1`, **never** `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for`
- Build a form from `to_form/2` assigned in the LiveView (`assign(socket, form: to_form(...))`), and in the template use `<.form for={@form} id="msg-form">` and `@form[:field]`. **Never** access the changeset in the template, and **never** use `<.form let={f} ...>`
- **Always** give key elements (forms, buttons and the like) unique DOM IDs, for the tests to use
- Elixir has `if/else` but **no `else if` or `elsif`**: use `cond` or `case` for multiple conditionals
- Literal `{` or `}` in a template (a code snippet in `<pre>` or `<code>`) needs `phx-no-curly-interpolation` on the parent tag
- Class attributes with several values use list syntax, wrapping `if` in parens:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100")
      ]}>Text</a>

- Generate template content with `<%= for item <- @collection do %>` (or `:for`), **never** `<% Enum.each %>`
- Template comments use `<%!-- comment --%>`
- Interpolate with `{...}` in attributes and for values in tag bodies; use `<%= ... %>` for block constructs (`if`, `cond`, `case`, `for`) in tag bodies. `<%= %>` inside an attribute is a syntax error

## LiveView guidelines

- Use `<.link navigate={href}>` and `<.link patch={href}>` in templates and `push_navigate` / `push_patch` in LiveViews, **never** the deprecated `live_redirect` and `live_patch`
- **Avoid LiveComponents** unless you have a strong, specific need for them
- LiveViews are named with a `Live` suffix, like `SlipdockWeb.BoardLive.Show`
- When you use streams, the parent element has `phx-update="stream"` and a DOM id, and each child uses the stream's id as its DOM id. Streams aren't enumerable and don't count: to filter, refetch and re-stream with `reset: true`; to show a count, keep it in a separate assign. **Never** use the deprecated `phx-update="append"` or `"prepend"`

### LiveView JavaScript interop

- A `phx-hook` element needs a unique DOM id, and a hook that manages its own DOM also needs `phx-update="ignore"`
- Scripts inside a template go in a colocated hook, `<script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">`, whose name **must** start with a `.`; colocated hooks are bundled into `app.js` by themselves
- External hooks live in `assets/js/` and are passed to the `LiveSocket` constructor in `app.js`
- Push events to a hook with `push_event/3`, and **always** return or rebind the socket it gives back; the hook listens with `this.handleEvent`. A hook calls the server with `this.pushEvent`, which a `handle_event` answers with `{:reply, map, socket}`

### LiveView tests

- Use `Phoenix.LiveViewTest` and `LazyHTML` for assertions; drive forms with `render_submit/2` and `render_change/2`
- Reference the element IDs you added in the templates: `element/2`, `has_element?/2`. Test outcomes, not implementation details, and prefer the presence of key elements to text that can change
- When a selector doesn't match, print the actual HTML narrowed with `LazyHTML.filter/2` rather than your mental model of it

<!-- usage-rules-end -->
