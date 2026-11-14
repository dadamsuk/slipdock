defmodule Slipdock.UncheckedWritesTest do
  @moduledoc """
  A context function that writes asks `Slipdock.Policy` who is writing
  (#3168; W-1945 §Permissions, *Where authorisation lives*). The ones that
  don't yet, in contexts the epic #3167 hasn't migrated, are listed in
  `test/support/unchecked_writes.txt`. A write that asks nobody and isn't
  listed fails here, and so does a listed line whose function now asks (or
  is gone), so the list can be emptied a context at a time.

  A repo check (`test/repo_checks.txt`): it reads `lib/slipdock/**` and runs
  in `mix pre_push`.
  """
  use ExUnit.Case, async: true

  alias Slipdock.UncheckedWrites

  @root Path.expand("../..", __DIR__)
  @list Path.join(@root, "test/support/unchecked_writes.txt")

  test "no context function writes without asking, beyond the ones listed" do
    {unlisted, stale} = UncheckedWrites.compare(@root, UncheckedWrites.read_list(@list))

    assert unlisted == [],
           "These write without asking who is writing. Call Slipdock.Policy.authorize/2 " <>
             "before the write (its action goes in Slipdock.Policy's table): " <>
             Enum.join(unlisted, ", ")

    assert stale == [],
           "These ask now, or are gone: take them off test/support/unchecked_writes.txt: " <>
             Enum.join(stale, ", ")
  end

  test "Boards.Tags asks for every write" do
    refute Enum.any?(
             UncheckedWrites.unchecked(@root),
             &String.starts_with?(&1, "Slipdock.Boards.Tags.")
           )
  end

  describe "on a tree made for the purpose" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "unchecked-writes-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "lib/slipdock"))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "lib/slipdock/things.ex"), """
      defmodule Slipdock.Things do
        alias Slipdock.Policy
        alias Slipdock.Repo
        alias Slipdock.Things.Store

        def unchecked(thing), do: Repo.insert(thing)
        def through_a_private(thing), do: save(thing)
        def through_another_module(thing), do: Store.put(thing)
        def piped(thing), do: thing |> save()
        def in_a_multi(thing), do: Ecto.Multi.new() |> Ecto.Multi.insert(:thing, thing)
        def as_the_server(thing), do: Policy.as_system("setup", fn -> Repo.insert(thing) end)

        def asks(thing) do
          with :ok <- Slipdock.Policy.authorize(:make_thing, thing), do: Repo.insert(thing)
        end

        def asks_through_a_private(thing), do: if(allowed(thing), do: save(thing))
        def asks_through_an_alias(thing), do: Policy.can?(:make_thing, thing) && save(thing)
        def reads(id), do: Repo.get(Thing, id)

        defp save(thing), do: Repo.update(thing)
        defp allowed(thing), do: Slipdock.Policy.authorize(:make_thing, thing) == :ok
      end
      """)

      # Its own check doesn't cover the caller above: that one trusts this one.
      File.write!(Path.join(root, "lib/slipdock/store.ex"), """
      defmodule Slipdock.Things.Store do
        def put(thing) do
          with :ok <- Slipdock.Policy.authorize(:make_thing, thing), do: Slipdock.Repo.insert(thing)
        end

        def wipe, do: Slipdock.Repo.delete_all(Thing)
      end
      """)

      %{root: root}
    end

    test "a write that asks nobody is found, directly or through a call", %{root: root} do
      assert UncheckedWrites.unchecked(root) == [
               "Slipdock.Things.Store.wipe/0",
               "Slipdock.Things.as_the_server/1",
               "Slipdock.Things.in_a_multi/1",
               "Slipdock.Things.piped/1",
               "Slipdock.Things.through_a_private/1",
               "Slipdock.Things.through_another_module/1",
               "Slipdock.Things.unchecked/1"
             ]
    end

    test "an unlisted write fails the check, and so does a listed line that now asks",
         %{root: root} do
      listed = [
        "Slipdock.Things.Store.wipe/0",
        "Slipdock.Things.as_the_server/1",
        "Slipdock.Things.in_a_multi/1",
        "Slipdock.Things.piped/1",
        "Slipdock.Things.through_a_private/1",
        "Slipdock.Things.through_another_module/1",
        # missing: Slipdock.Things.unchecked/1
        "Slipdock.Things.asks/1",
        "Slipdock.Things.gone/0"
      ]

      assert UncheckedWrites.compare(root, listed) ==
               {["Slipdock.Things.unchecked/1"],
                ["Slipdock.Things.asks/1", "Slipdock.Things.gone/0"]}

      assert UncheckedWrites.compare(root, UncheckedWrites.unchecked(root)) == {[], []}
    end

    test "a list file's blank lines and comments are skipped", %{root: root} do
      path = Path.join(root, "list.txt")
      File.write!(path, "# a comment\n\nSlipdock.Things.piped/1\n  \n")
      assert UncheckedWrites.read_list(path) == ["Slipdock.Things.piped/1"]
    end
  end
end
