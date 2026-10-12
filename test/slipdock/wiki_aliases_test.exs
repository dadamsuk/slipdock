defmodule Slipdock.WikiAliasesTest do
  @moduledoc "Aliases as link targets (W-103 R3.5): `[[Alias]]` finds the page whose front matter names it."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Archive, Page}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Brain", "code" => "aliases"}, owner: user)
    %{user: user, board: board}
  end

  defp import!(board, user, path, text) do
    %{created: [page]} = Archive.import_files(board, [{path, text}], user: user)
    Wiki.get_page!(page.id)
  end

  defp target(page), do: page |> Wiki.outgoing_links() |> hd() |> Map.get(:target_page_id)

  test "aliases come from the front matter: a list, a comma string, or the older alias" do
    assert Page.aliases_from("---\naliases: [One, \"Two words\"]\n---\n") == ["One", "Two words"]
    assert Page.aliases_from("---\naliases:\n  - One\n  - one\n---\n") == ["One"]
    assert Page.aliases_from("---\naliases: One, Two\n---\n") == ["One", "Two"]
    assert Page.aliases_from("---\nalias: Old style\n---\n") == ["Old style"]
    assert Page.aliases_from("---\naliases: []\n---\n") == []
    assert Page.aliases_from(nil) == []
  end

  test "an imported note answers to its aliases, case-insensitively", %{board: board, user: user} do
    note = import!(board, user, "Retry policy.md", "---\naliases: [Retries, Backoff]\n---\nText")
    assert note.aliases == ["Retries", "Backoff"]

    {:ok, other} =
      Wiki.create_page(board, %{"title" => "Other", "body" => "See [[backoff]]."}, user: user)

    assert target(other) == note.id
    assert {:ok, %{id: id}} = Wiki.find_page(board, "RETRIES")
    assert id == note.id
  end

  test "a title beats an alias", %{board: board, user: user} do
    _aliased = import!(board, user, "A.md", "---\naliases: [Shared]\n---\nx")
    {:ok, titled} = Wiki.create_page(board, %{"title" => "Shared", "body" => "y"}, user: user)

    {:ok, other} =
      Wiki.create_page(board, %{"title" => "Linker", "body" => "[[Shared]]"}, user: user)

    assert target(other) == titled.id
  end

  test "a link wanted before the alias existed comes alive when it is added", %{
    board: board,
    user: user
  } do
    {:ok, linker} =
      Wiki.create_page(board, %{"title" => "Linker", "body" => "[[Nickname]]"}, user: user)

    assert [%{resolved: false}] = Wiki.outgoing_links(linker)

    {:ok, page} = Wiki.create_page(board, %{"title" => "Real name", "body" => "z"}, user: user)

    {:ok, page} =
      Wiki.update_page(page, %{"front_matter" => "---\naliases: [Nickname]\n---\n\n"}, user: user)

    assert page.aliases == ["Nickname"]
    assert target(linker) == page.id
  end

  test "taking an alias away leaves an id-stored link pointing where it did", %{
    board: board,
    user: user
  } do
    page = import!(board, user, "Real.md", "---\naliases: [Nick]\n---\nz")

    {:ok, linker} =
      Wiki.create_page(board, %{"title" => "Linker", "body" => "[[Nick]]"}, user: user)

    {:ok, page} = Wiki.update_page(page, %{"front_matter" => nil}, user: user)

    assert page.aliases == []
    assert target(linker) == page.id
  end
end
