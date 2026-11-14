defmodule SlipdockWeb.CopyTest do
  @moduledoc """
  `copy_block/1` and `secret_once/1` (#2887): text to copy with the button
  that copies it, written once for the agent setup, a Tool's install steps,
  the help's snippets, a runner's setup steps and the one-time secrets.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias SlipdockWeb.SlipdockComponents

  defp parse(html), do: LazyHTML.from_fragment(html)

  defp one(doc, selector),
    do: doc |> LazyHTML.query(selector) |> Enum.to_list() |> then(fn [n] -> n end)

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp text(node), do: node |> LazyHTML.text() |> String.trim()

  describe "copy_block/1" do
    test "a wrapped, selectable code block with a CopyText button under it" do
      assigns = %{}

      doc =
        rendered_to_string(~H"""
        <SlipdockComponents.copy_block id="install" text="curl -fsSL https://example.com/install.sh | sh" />
        """)
        |> parse()

      code = one(doc, "code#install")
      assert text(code) == "curl -fsSL https://example.com/install.sh | sh"
      assert attr(code, "class") =~ "select-all"
      assert attr(code, "class") =~ "whitespace-pre-wrap"

      button = one(doc, "button#install-copy[type=button]")
      assert attr(button, "phx-hook") == "CopyText"
      assert attr(button, "data-target") == "install"
      assert button |> LazyHTML.query("[data-label]") |> text() == "Copy"
      assert button |> LazyHTML.query(".hero-clipboard") |> Enum.count() == 1
      assert doc |> LazyHTML.query("pre") |> Enum.empty?()
    end

    test "the label names the button, and class goes on the wrapper" do
      assigns = %{}

      doc =
        rendered_to_string(~H"""
        <SlipdockComponents.copy_block id="p" text="hi" label="Copy prompt" class="mt-3" />
        """)
        |> parse()

      assert doc |> LazyHTML.query("#p-copy [data-label]") |> text() == "Copy prompt"
      assert doc |> LazyHTML.query("div.mt-3 > code#p") |> Enum.count() == 1
    end

    test "the text is escaped, never markup" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SlipdockComponents.copy_block id="x" text="<script>alert(1)</script>" />
        """)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "pre keeps the lines in a <pre>, with the button in its corner" do
      assigns = %{text: "one\ntwo"}

      doc =
        rendered_to_string(~H"""
        <SlipdockComponents.copy_block id="step-1" text={@text} pre class="mb-2" />
        """)
        |> parse()

      pre = one(doc, "div.relative.mb-2 > pre#step-1")
      assert LazyHTML.text(pre) == "one\ntwo"
      assert attr(pre, "class") =~ "whitespace-pre"
      refute attr(pre, "class") =~ "whitespace-pre-wrap"

      button = one(doc, "button#step-1-copy")
      assert attr(button, "phx-hook") == "CopyText"
      assert attr(button, "data-target") == "step-1"
      assert attr(button, "class") =~ "absolute"
      assert button |> LazyHTML.query("[data-label]") |> text() == "Copy"
      assert doc |> LazyHTML.query("code") |> Enum.empty?()
    end
  end

  describe "secret_once/1" do
    test "says to copy it now, gives it a Copy button, and a Done that dismisses it" do
      assigns = %{}

      doc =
        rendered_to_string(~H"""
        <SlipdockComponents.secret_once
          id="new-token"
          text="sdk_abc"
          what="token"
          dismiss="dismiss_token"
          target="#tokens"
        />
        """)
        |> parse()

      box = one(doc, "#new-token-once[data-secret-once]")

      # A warning callout (COMP-6), its title the instruction.
      assert attr(box, "data-callout") == "warning"

      assert box |> LazyHTML.query("p.font-semibold") |> text() ==
               "Copy this token now — it won't be shown again."

      assert box |> LazyHTML.query("code#new-token") |> text() == "sdk_abc"

      assert attr(one(box, "button#new-token-copy"), "data-target") == "new-token"

      done =
        box
        |> LazyHTML.query("button[phx-click]")
        |> Enum.to_list()
        |> then(fn [b] -> b end)

      assert text(done) == "Done"
      assert attr(done, "phx-click") == "dismiss_token"
      assert attr(done, "phx-target") == "#tokens"
    end
  end
end
