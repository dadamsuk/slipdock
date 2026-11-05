defmodule Slipdock.Gardener.Checks.BroadCovers do
  @moduledoc """
  Handbook pages that cover nearly everything (#1790): a `covers:` glob so
  broad that it matches almost any path a card names, so the page is
  suggested for every card and pushes the better suggestions out.

  A glob counts as broad when it has `**` in it and what comes before its
  first wildcard holds fewer than two whole folders: `**` and `lib/**` are
  broad; `lib/app/**` and `config/*.exs` are not.

  The fix comments on the Index saying which page to narrow, and to what
  kind of glob. Off on a board without a handbook.
  """
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.HandbookNote
  alias Slipdock.Handbook

  @impl true
  def key, do: "broad_covers"
  @impl true
  def label, do: "Handbook pages that cover everything"
  @impl true
  def defaults, do: %{"enabled" => true}

  @impl true
  def find(ctx, _settings) do
    case HandbookNote.handbook(ctx) do
      nil ->
        []

      handbook ->
        for page <- handbook.pages,
            globs = covers(page),
            broad = Enum.filter(globs, &broad?/1),
            broad != [],
            do: finding(handbook, page, globs, broad)
    end
  end

  defp covers(page),
    do: page |> Handbook.field("covers") |> List.wrap() |> Enum.filter(&is_binary/1)

  @doc "Whether `glob` matches nearly everything (see the moduledoc)."
  def broad?(glob) do
    glob = String.trim(glob)

    folders =
      glob
      |> String.split(~r/[*?\[{]/, parts: 2)
      |> hd()
      |> String.split("/")
      |> Enum.drop(-1)
      |> Enum.reject(&Enum.member?(["", "."], &1))

    String.contains?(glob, "**") and length(folders) < 2
  end

  defp finding(handbook, page, globs, broad) do
    listed = Enum.map_join(broad, ", ", &"`#{&1}`")

    HandbookNote.finding(
      handbook,
      [page],
      globs,
      "“#{page.title}” covers #{listed}, which matches nearly every path, " <>
        "so it is suggested for every card",
      "Narrow `covers:` on #{HandbookNote.name(page)} to the files whose change would make " <>
        "it wrong, like `lib/app/accounts/**` rather than `lib/**` " <>
        "(`slipdock page props #{page.code || page.id}`)."
    )
  end
end
