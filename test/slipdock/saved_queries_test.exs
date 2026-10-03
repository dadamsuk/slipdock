defmodule Slipdock.SavedQueriesTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.SavedQueries

  @examples ["an example", "another example"]

  setup do
    %{user: user_fixture("owner@example.com"), other: user_fixture("other@example.com")}
  end

  test "saves a query under a mode, and lists it back", ctx do
    assert {:ok, saved} = SavedQueries.save(ctx.user, "search", "flaky tests")
    assert saved.mode == "search"
    assert saved.text == "flaky tests"

    assert [%{text: "flaky tests"}] = SavedQueries.list(ctx.user, "search")
    assert SavedQueries.list(ctx.user, "ask") == []
  end

  test "the two modes keep separate lists, so the same words can live in both", ctx do
    {:ok, _} = SavedQueries.save(ctx.user, "search", "refunds")
    {:ok, _} = SavedQueries.save(ctx.user, "ask", "refunds")

    assert [%{mode: "search"}] = SavedQueries.list(ctx.user, "search")
    assert [%{mode: "ask"}] = SavedQueries.list(ctx.user, "ask")
    assert length(SavedQueries.list(ctx.user)) == 2
  end

  test "saving the same thing twice is saving it once", ctx do
    assert {:ok, first} = SavedQueries.save(ctx.user, "search", "refunds")
    assert {:ok, again} = SavedQueries.save(ctx.user, "search", "refunds")

    assert again.id == first.id
    assert length(SavedQueries.list(ctx.user, "search")) == 1
  end

  test "text is trimmed, and blank or over-long text is refused", ctx do
    assert {:ok, saved} = SavedQueries.save(ctx.user, "search", "  spaced out  ")
    assert saved.text == "spaced out"

    assert {:error, %Ecto.Changeset{}} = SavedQueries.save(ctx.user, "search", "   ")

    assert {:error, %Ecto.Changeset{}} =
             SavedQueries.save(ctx.user, "search", String.duplicate("x", 301))
  end

  test "an unknown mode is refused rather than stored", ctx do
    assert {:error, :bad_mode} = SavedQueries.save(ctx.user, "shout", "hello")
    assert SavedQueries.list(ctx.user) == []
  end

  test "saved? and toggle", ctx do
    refute SavedQueries.saved?(ctx.user, "search", "refunds")

    assert {:ok, :saved} = SavedQueries.toggle(ctx.user, "search", "refunds")
    assert SavedQueries.saved?(ctx.user, "search", "refunds")
    # The same words in the other mode are a different thing.
    refute SavedQueries.saved?(ctx.user, "ask", "refunds")

    assert {:ok, :removed} = SavedQueries.toggle(ctx.user, "search", "refunds")
    refute SavedQueries.saved?(ctx.user, "search", "refunds")
  end

  test "removing by text and by id, and only ever your own", ctx do
    {:ok, mine} = SavedQueries.save(ctx.user, "search", "mine")
    {:ok, theirs} = SavedQueries.save(ctx.other, "search", "theirs")

    # Someone else's id is not yours to delete.
    :ok = SavedQueries.delete(ctx.user, theirs.id)
    assert [%{text: "theirs"}] = SavedQueries.list(ctx.other, "search")

    :ok = SavedQueries.delete(ctx.user, mine.id)
    assert SavedQueries.list(ctx.user, "search") == []

    {:ok, _} = SavedQueries.save(ctx.user, "ask", "by text")
    :ok = SavedQueries.remove(ctx.user, "ask", "  by text  ")
    assert SavedQueries.list(ctx.user, "ask") == []
    # Removing what was never there is not an error.
    :ok = SavedQueries.remove(ctx.user, "ask", "never existed")
  end

  test "saved queries are personal: nobody sees anybody else's", ctx do
    {:ok, _} = SavedQueries.save(ctx.user, "search", "mine alone")
    assert SavedQueries.list(ctx.other, "search") == []
    refute SavedQueries.saved?(ctx.other, "search", "mine alone")
  end

  describe "examples_for/3" do
    test "offers the built-in examples until something is saved", ctx do
      assert {:examples, @examples} = SavedQueries.examples_for(ctx.user, "ask", @examples)

      {:ok, _} = SavedQueries.save(ctx.user, "ask", "my own question")

      assert {:saved, [%{text: "my own question"}]} =
               SavedQueries.examples_for(ctx.user, "ask", @examples)
    end

    test "one saved query in one mode leaves the other mode's examples alone", ctx do
      {:ok, _} = SavedQueries.save(ctx.user, "ask", "my own question")

      assert {:saved, _} = SavedQueries.examples_for(ctx.user, "ask", @examples)
      assert {:examples, @examples} = SavedQueries.examples_for(ctx.user, "search", @examples)
    end

    test "unsaving the last one brings the examples back", ctx do
      {:ok, saved} = SavedQueries.save(ctx.user, "search", "mine")
      assert {:saved, _} = SavedQueries.examples_for(ctx.user, "search", @examples)

      :ok = SavedQueries.delete(ctx.user, saved.id)
      assert {:examples, @examples} = SavedQueries.examples_for(ctx.user, "search", @examples)
    end

    test "nobody signed in gets the examples", _ctx do
      assert {:examples, @examples} = SavedQueries.examples_for(nil, "ask", @examples)
    end
  end

  test "newest first — the thing you just saved is the one at the top", ctx do
    # Timestamps have second resolution, so three saves in a row share one.
    # The id is the tiebreaker, which is what keeps the order stable.
    for text <- ["first", "second", "third"] do
      {:ok, _} = SavedQueries.save(ctx.user, "search", text)
    end

    assert ["third", "second", "first"] =
             ctx.user |> SavedQueries.list("search") |> Enum.map(& &1.text)
  end
end
