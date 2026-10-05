defmodule Slipdock.PortableExportTest do
  @moduledoc """
  What the document holds, and above all what the old flat export lost: a
  card's subcards, its tags, its checklist, its comments, its custom field
  values and what it waits on. An export whose import cannot rebuild the board
  is not an export, so these tests are about completeness rather than shape.
  """
  # Not async, like the other portable tests: each test makes more than one
  # top-level board, and a board's code and shortcut are picked as "the first
  # one free" and then inserted. Run alongside another test doing the same, the
  # two sandboxed transactions can each hold a key the other wants, and
  # Postgres ends it with a deadlock.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Portable, Wiki}

  defp tree do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Delivery", "code" => "del"}, owner: owner)
    [_backlog, todo, doing | _] = board.columns

    tag = tag_fixture(board, "urgent", "rose")
    {:ok, field} = Fields.create_field(board, %{"name" => "Points", "kind" => "number"})

    epic = card_fixture(todo, %{"title" => "Ship it"})
    other = card_fixture(doing, %{"title" => "Groundwork"})

    {:ok, _} = Boards.set_card_tags(epic, [tag])
    {:ok, _} = Boards.add_checklist_item(epic, "Write it down")
    {:ok, _} = Boards.add_comment(epic, "Started on this")

    {:ok, _} =
      Boards.add_status_update(epic, owner, %{"health" => "on_track", "body" => "On track"})

    {:ok, _} = Boards.add_card_url(epic, %{"url" => "https://example.com", "title" => "Spec"})
    {:ok, _} = Fields.set_value(epic, field, "8")
    {:ok, _} = Boards.add_dependency(epic, other)
    {:ok, _} = Boards.add_link(epic, other, "relates")

    template = Boards.list_templates() |> Enum.find(&(&1.name == "Simple"))
    {:ok, sub} = Boards.create_sub_board(epic, template)
    [sub_todo | _] = Boards.get_board!(sub.id).columns
    subcard = card_fixture(sub_todo, %{"title" => "One sitting of it"})

    {:ok, page} =
      Wiki.create_page(board, %{"title" => "How it works", "body" => "The shape of it."},
        user: owner
      )

    %{
      owner: owner,
      board: board,
      epic: epic,
      other: other,
      sub: sub,
      subcard: subcard,
      page: page,
      tag: tag,
      field: field
    }
  end

  defp only_tree(user, opts \\ []) do
    %{boards: [tree]} = Portable.export(user, opts)
    tree
  end

  defp card(tree, title), do: Enum.find(tree.cards, &(&1.title == title))

  describe "the document" do
    test "says which format it is, so a reader never has to guess" do
      %{owner: owner} = tree()
      document = Portable.export(owner)

      assert document.slipdock_portable == Portable.format_version()
      assert document.exported_by == "owner@example.com"
      assert document.exported_from.commit == Slipdock.Build.sha()
    end

    test "takes every root board the user owns, and nobody else's" do
      %{owner: owner} = tree()
      _theirs = board_fixture(%{"name" => "Not yours"}, owner: user_fixture("other@example.com"))

      assert [%{root: %{name: "Delivery"}}] = Portable.export(owner).boards
    end

    test "takes only the boards asked for when a subset is named" do
      %{owner: owner, board: board} = tree()
      _second = board_fixture(%{"name" => "Second"}, owner: owner)

      assert [%{root: %{name: "Delivery"}}] = Portable.export(owner, boards: [board]).boards
    end

    test "asking for a sub-board gives the whole tree it belongs to" do
      # Its tags and fields live on the root, so half a tree would be a
      # document that cannot be imported.
      %{owner: owner, sub: sub} = tree()

      assert [%{root: %{name: "Delivery"}}] = Portable.export(owner, boards: [sub]).boards
    end
  end

  describe "what the flat export used to lose" do
    test "a card's subcards, as a board the card points at" do
      %{owner: owner} = tree()
      t = only_tree(owner)

      epic = card(t, "Ship it")
      assert epic.subcards
      sub = Enum.find(t.boards, &(&1.ref == epic.subcards))
      assert sub.inside_card == epic.ref
      assert card(t, "One sitting of it").board == sub.ref
    end

    test "tags, by ref into the tree's own tag list" do
      %{owner: owner} = tree()
      t = only_tree(owner)

      assert [%{name: "urgent", color: "rose", ref: ref}] = t.tags
      assert card(t, "Ship it").tags == [ref]
    end

    test "the checklist, the comments and the status updates" do
      %{owner: owner} = tree()
      epic = only_tree(owner) |> card("Ship it")

      assert [%{text: "Write it down", done: false}] = epic.checklist
      assert [%{body: "Started on this"}] = epic.comments

      assert [%{health: "on_track", body: "On track", author: "owner@example.com"}] =
               epic.status_updates
    end

    test "custom fields, and the values cards hold in them" do
      %{owner: owner} = tree()
      t = only_tree(owner)

      assert [%{name: "Points", kind: "number", ref: ref}] = t.fields
      assert [%{field: ^ref, number: 8.0}] = card(t, "Ship it").fields
    end

    test "what a card waits on, and what it is linked to" do
      %{owner: owner} = tree()
      t = only_tree(owner)

      epic = card(t, "Ship it")
      other = card(t, "Groundwork")

      assert epic.blocked_by == [other.ref]
      assert [%{kind: "relates", to: other_ref}] = epic.links
      assert other_ref == other.ref
    end

    test "web links" do
      %{owner: owner} = tree()

      assert [%{url: "https://example.com", title: "Spec"}] =
               only_tree(owner) |> card("Ship it") |> Map.fetch!(:urls)
    end

    test "wiki pages, with their body" do
      %{owner: owner} = tree()
      assert [%{title: "How it works", body: "The shape of it."}] = only_tree(owner).pages
    end
  end

  describe "archived things are left out unless asked for" do
    test "cards" do
      %{owner: owner, other: other} = tree()
      {:ok, _} = Boards.archive_card(other)

      refute only_tree(owner) |> card("Groundwork")
      assert only_tree(owner, archived_cards: true) |> card("Groundwork")
    end

    test "wiki pages" do
      %{owner: owner, page: page} = tree()
      {:ok, _} = Wiki.archive_page(page)

      assert only_tree(owner).pages == []
      assert [%{title: "How it works"}] = only_tree(owner, archived_pages: true).pages
    end

    test "whole boards" do
      %{owner: owner} = tree()
      second = board_fixture(%{"name" => "Put away"}, owner: owner)
      {:ok, _} = Boards.archive_board(second)

      names = fn opts -> Portable.export(owner, opts).boards |> Enum.map(& &1.root.name) end

      assert names.([]) == ["Delivery"]
      assert names.(archived_boards: true) == ["Delivery", "Put away"]
    end
  end

  describe "nothing inside the document is a database id" do
    test "every ref a card points at resolves inside the same document" do
      %{owner: owner} = tree()
      t = only_tree(owner)

      lists = Enum.flat_map([t.root | t.boards], & &1.lists) |> Enum.map(& &1.ref)
      cards = Enum.map(t.cards, & &1.ref)
      boards = Enum.map([t.root | t.boards], & &1.ref)

      for card <- t.cards do
        assert card.list in lists
        assert card.board in boards
        assert card.subcards == nil or card.subcards in boards
        for ref <- card.blocked_by, do: assert(ref in cards)
        for link <- card.links, do: assert(link.to in cards)
        for ref <- card.tags, do: assert(ref in Enum.map(t.tags, & &1.ref))
      end
    end

    test "it survives a trip through JSON, which is how it will travel" do
      %{owner: owner} = tree()

      decoded =
        owner |> Portable.export() |> Jason.encode!() |> Jason.decode!()

      assert decoded["slipdock_portable"] == Portable.format_version()
      assert [%{"root" => %{"name" => "Delivery"}}] = decoded["boards"]
    end
  end

  describe "what it says it is leaving behind" do
    test "nothing, when there was nothing of the kind to leave" do
      bare = user_fixture("bare@example.com")
      _board = board_fixture(%{"name" => "Nothing on it"}, owner: bare)

      assert Portable.warnings(bare) == []
    end

    test "dependencies on cards on a board outside the export" do
      %{owner: owner, board: board, epic: epic, subcard: subcard} = tree()
      outside = board_fixture(%{"name" => "Outside", "code" => "outs"}, owner: owner)
      far = card_fixture(hd(outside.columns), %{"title" => "Far away"})
      {:ok, _} = Boards.add_dependency(epic, far)
      # Inside one tree — a subcard on the epic it belongs to's board — is kept.
      {:ok, _} = Boards.add_dependency(subcard, epic)

      assert [warning] =
               owner
               |> Portable.warnings(boards: [board])
               |> Enum.filter(&(&1 =~ "Dependencies between"))

      assert warning =~ "1 left behind"

      [tree] = Portable.export(owner, boards: [board]).boards
      exported_epic = Enum.find(tree.cards, &(&1.title == "Ship it"))
      assert length(exported_epic.blocked_by) == 1

      # Exported together they are still two trees, each with refs of its own.
      assert Enum.any?(Portable.warnings(owner), &(&1 =~ "Dependencies between"))
    end

    test "wiki history, which a page has from the moment it is written" do
      %{owner: owner, page: page} = tree()
      {:ok, _} = Wiki.update_page(page, %{"body" => "Rewritten."}, user: owner)

      assert [warning] = Portable.warnings(owner)
      assert warning =~ "Wiki page history is not in this file"
      assert warning =~ "left behind"
    end
  end
end
