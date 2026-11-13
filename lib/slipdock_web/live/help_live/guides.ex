defmodule SlipdockWeb.HelpLive.Guides do
  @moduledoc """
  Help's guides to the app itself: boards, the wiki, sharing, email, automations,
  Tools and the AI features. Each is one page of short parts; the hub lists the parts so
  a reader can jump straight to one. The part ids here are those anchors, so
  a part's `id` in its page and in `@sections` have to agree (the tests check).

  The module is the code; the words are beside it (#2919). Each guide is a
  HEEx template, `guides/<slug>.html.heex`, embedded here as `<slug>/1`, and
  the list of guides (title, intro, parts) is `guides/sections.exs`.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.HelpLive.Components

  # The guides, in the hub's order, each with its parts' anchors and titles.
  @sections_file Path.join(__DIR__, "guides/sections.exs")
  @external_resource @sections_file
  @sections @sections_file |> Code.eval_file() |> elem(0)

  @slugs Enum.map(@sections, & &1.slug)

  def sections, do: @sections
  def slugs, do: @slugs

  embed_templates "guides/*.html"

  attr :slug, :string, required: true
  attr :current_user, :any, required: true

  # One clause a guide, calling its template.
  for slug <- @slugs do
    def guide(%{slug: unquote(slug)} = assigns),
      do: unquote(String.to_existing_atom(slug))(assigns)
  end
end
