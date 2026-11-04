defmodule SlipdockWeb.ButtonsTest do
  @moduledoc """
  Brand system 3 (#1703): the button hierarchy.

  - Primary (`btn-primary`) is the solid primary, at most one per form.
  - Secondary (`btn-secondary`) is the soft tint; a plain `btn` is a neutral
    surface with a hairline. `btn-outline` (the near-black border) is gone.
  - Tertiary is `btn-ghost`.
  - Destructive is `btn-ghost btn-error`, behind `data-confirm`; the solid
    `btn-error` only in a step that already is the confirmation.
  - A button in a row with a field is `btn-sm`, and the row is `field-row`.

  The look itself lives in the Buttons block of `assets/css/app.css`; the
  contrast of its labels is in `design_tokens_test.exs`. The browser check
  is `tools/e2e/buttons.sh`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  @css File.read!("assets/css/app.css")

  # A button-ish tag, attributes spanning lines, quoted values and {…}
  # expressions included (neither may hide a `>`).
  @tag_re ~r/<(?:button|a|\.link|\.button|label)\b(?:[^>"{]|"[^"]*"|\{(?:[^{}]|\{[^{}]*\})*\})*>/s

  # Destructive buttons that need no `data-confirm`, and why.
  @unconfirmed %{
    # Inside the passphrase dialog: the dialog is the confirmation.
    {"lib/slipdock_web/components/layouts.ex", "data-meld-remove"} => :inside_a_dialog,
    # Opens the step that asks for the address typed out, then confirms.
    {"lib/slipdock_web/live/users_live/index.ex", ~s(phx-click="confirm-delete")} =>
      :opens_a_confirm_step,
    # Takes a row out of a template form nothing has saved yet.
    {"lib/slipdock_web/live/template_live/index.ex", ~s(phx-click="remove_column")} =>
      :unsaved_form_row
  }

  # Solid `btn-error` buttons, each the second step of a confirmation.
  @solid_error %{
    "lib/slipdock_web/live/users_live/index.ex" => 1,
    # The wiki tree's archive and delete prompts.
    "lib/slipdock_web/live/wiki_live/index.ex" => 5
  }

  defp sources do
    Path.wildcard("lib/slipdock_web/**/*.{ex,heex}")
    |> Enum.map(&{&1, File.read!(&1)})
  end

  @doc false
  # The `btn` tags in a source, each as {line, tag}.
  def button_tags(src) do
    for [{start, len}] <- Regex.scan(@tag_re, src, return: :index),
        tag = binary_part(src, start, len),
        tag =~ ~r/["\s]btn["\s]/ do
      {src |> binary_part(0, start) |> String.split("\n") |> length(), tag}
    end
  end

  defp destructive?(tag), do: tag =~ ~r/\bbtn-ghost\b/ and tag =~ ~r/\bbtn-error\b/
  defp solid_error?(tag), do: tag =~ ~r/\bbtn-error\b/ and not (tag =~ ~r/\bbtn-ghost\b/)

  defp exempt?(path, tag),
    do: Enum.any?(@unconfirmed, fn {{p, marker}, _} -> p == path and tag =~ marker end)

  describe "the scanners" do
    test "find button tags across lines, with their line" do
      src = ~s(<p>x</p>\n<button\n  class="btn btn-ghost btn-error"\n  data-confirm="Sure?"\n>)
      assert [{2, tag}] = button_tags(src)
      assert destructive?(tag)
      assert tag =~ "data-confirm"
    end

    test "tell a destructive ghost from a solid error and from neither" do
      refute destructive?(~s(<button class="btn btn-error">))
      assert solid_error?(~s(<button class="btn btn-error">))
      refute solid_error?(~s(<button class="btn btn-ghost btn-error">))
      refute destructive?(~s(<button class="btn btn-ghost text-sm">))
      assert button_tags(~s(<button class="btn-group">)) == []
    end
  end

  describe "the templates" do
    test "no btn-outline anywhere: the near-black border is retired" do
      found =
        for {path, src} <- sources(),
            {line, n} <- src |> String.split("\n") |> Enum.with_index(1),
            line =~ ~r/\bbtn-outline\b/,
            do: "#{path}:#{n}"

      assert found == [],
             "btn-outline is retired; use btn, btn-secondary or btn-ghost:\n" <>
               Enum.join(found, "\n")
    end

    test "a destructive ghost button asks first" do
      found =
        for {path, src} <- sources(),
            {n, tag} <- button_tags(src),
            destructive?(tag),
            not (tag =~ "data-confirm"),
            not exempt?(path, tag),
            do: "#{path}:#{n}"

      assert found == [], "add data-confirm to:\n" <> Enum.join(found, "\n")
    end

    test "destructive buttons are btn-error, not ghosts painted with text-error" do
      found =
        for {path, src} <- sources(),
            {n, tag} <- button_tags(src),
            tag =~ ~r/class="[^"]*\bbtn-ghost\b[^"]*\btext-error\b/,
            do: "#{path}:#{n}"

      assert found == []
    end

    test "the solid error button is only the second step of a confirmation" do
      counts =
        for {path, src} <- sources(),
            n = src |> button_tags() |> Enum.count(fn {_, tag} -> solid_error?(tag) end),
            n > 0,
            into: %{},
            do: {path, n}

      assert counts == @solid_error
    end

    test "the exemptions still point at something" do
      for {{path, marker}, _why} <- @unconfirmed do
        assert path |> File.read!() |> button_tags() |> Enum.any?(fn {_, t} -> t =~ marker end),
               "#{path}: no button with #{marker}; drop it from @unconfirmed"
      end
    end

    test "a button in a field row is btn-sm" do
      rows =
        for {path, src} <- sources(),
            [{start, _}] <- Regex.scan(~r/class="[^"]*\bfield-row\b/, src, return: :index) do
          # The row's own button: the first after the row opens.
          rest = binary_part(src, start, byte_size(src) - start)
          [{_, tag} | _] = button_tags(rest)
          {path, String.replace(tag, ~r/\s+/, " ")}
        end

      assert length(rows) >= 8, "the field rows the sweep made have gone: #{inspect(rows)}"
      assert for({path, tag} <- rows, not (tag =~ ~r/\bbtn-(?:sm|xs)\b/), do: {path, tag}) == []
    end

    test "<.button> maps each variant to its class" do
      for {variant, class} <- [
            {"primary", "btn btn-primary"},
            {"secondary", "btn btn-secondary"},
            {"ghost", "btn btn-ghost"},
            {"danger", "btn btn-ghost btn-error"}
          ] do
        assigns = %{variant: variant}

        html =
          rendered_to_string(~H"""
          <SlipdockWeb.CoreComponents.button variant={@variant}>Go</SlipdockWeb.CoreComponents.button>
          """)

        assert html =~ ~s(class="#{class}"), variant
      end

      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SlipdockWeb.CoreComponents.button>Cancel</SlipdockWeb.CoreComponents.button>
        """)

      assert html =~ ~s(class="btn")
      refute html =~ "btn-soft"
    end
  end

  describe "app.css" do
    test "the primary is the solid fill, not a tint" do
      [_, block] = Regex.run(~r/\n\.btn-primary \{(.*?)\}/s, @css) || [nil, ""]
      refute block =~ "color-mix", "btn-primary is a tint again: #{block}"
      refute @css =~ ~r/\.btn-primary\s*\{[^}]*--btn-fg:\s*var\(--color-primary\)/
    end

    test "the secondary is a soft tint of the primary with primary words" do
      assert [_, pct] =
               Regex.run(
                 ~r/\.btn-secondary \{\s*--btn-color: color-mix\(in oklab, var\(--color-primary\) (\d+)%, var\(--color-base-100\)\);\s*--btn-fg: var\(--color-primary\);/,
                 @css
               )

      assert String.to_integer(pct) in 6..20
    end

    test "the plain button is a hairline on base-100, scoped away from the coloured ones" do
      [_, selector, body] =
        Regex.run(
          ~r/\n(\.btn:not\([^{]*?\)) \{\s*(--btn-color: var\(--color-base-100\);.*?)\}/s,
          @css
        )

      assert body =~ "--btn-border: color-mix(in oklab, var(--color-base-content) 20%"

      for class <- ~w(btn-ghost btn-primary btn-secondary btn-error btn-link) do
        assert selector =~ ".#{class}", "the neutral surface would land on .#{class}"
      end
    end

    test "a field row lines the field's wrapper up with the button" do
      assert @css =~ ~r/\.field-row \{\s*display: flex;\s*align-items: flex-end;/
      assert @css =~ ~r/\.field-row \.fieldset \{\s*margin-bottom: 0;\s*padding-bottom: 0;/
    end
  end

  describe "one primary per form, on the pages the sweep covered" do
    setup %{conn: conn} do
      {:ok, _} =
        Settings.complete_setup(%{"admin_email" => "admin@example.com", "signup_mode" => :closed})

      {:ok, admin} = Accounts.promote(user_fixture("btnadmin@example.com"))
      board = board_fixture(%{}, owner: admin)
      [column | _] = Slipdock.Repo.preload(board, :columns).columns
      card = card_fixture(column, %{"title" => "Buttons"})
      tag_fixture(board, "ux")
      %{conn: log_in_user(conn, admin), board: board, card: card}
    end

    test "Account, Config, Users, Groups, home, the wiki editor, tags, automations and the card back",
         %{conn: conn, board: board, card: card} do
      paths =
        ~w(/ /account /account/settings /account/tokens /account/data /config /config/mail
           /config/meetings /config/ai /users /groups) ++
          [
            "/boards/#{board.id}/wiki/new",
            "/boards/#{board.id}/tags",
            "/boards/#{board.id}/automations",
            "/boards/#{board.id}/settings",
            "/boards/#{board.id}/cards/#{card.id}"
          ]

      for path <- paths do
        {:ok, _view, html} = live(conn, path)
        doc = LazyHTML.from_document(html)

        assert LazyHTML.query(doc, ".btn-outline") |> Enum.count() == 0, path

        for form <- LazyHTML.query(doc, "form") do
          n = form |> LazyHTML.query(".btn-primary") |> Enum.count()
          id = form |> LazyHTML.attribute("id") |> List.first()
          assert n <= 1, "#{path}: form #{id || "(no id)"} has #{n} primary buttons"
        end
      end
    end

    test "the account's Save is the solid primary beside its fields, at btn-sm", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/account")
      doc = LazyHTML.from_document(html)
      assert [_] = doc |> LazyHTML.query("#profile-form.field-row") |> Enum.to_list()

      assert doc
             |> LazyHTML.query("#profile-form button[type=submit]")
             |> LazyHTML.attribute("class") == ["btn btn-primary btn-sm"]
    end

    test "the sign-in page has no outline and at most one primary per form" do
      conn = Phoenix.ConnTest.build_conn()
      {:ok, _view, html} = live(conn, ~p"/login")
      doc = LazyHTML.from_document(html)
      assert LazyHTML.query(doc, ".btn-outline") |> Enum.count() == 0

      for form <- LazyHTML.query(doc, "form") do
        assert form |> LazyHTML.query(".btn-primary") |> Enum.count() <= 1
      end
    end
  end
end
