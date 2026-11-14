defmodule Slipdock.UncheckedWritesTest do
  @moduledoc """
  SPIKE #3162, not for merging: the repo check the plan proposes.

  A public context function that writes must ask `Slipdock.Policy` (or, until
  its context is migrated, `Slipdock.Access`) in its own module. The ones
  that don't yet are listed in `test/support/unchecked_writes.txt`. A write
  not on the list fails here; so does a line whose function now asks, so the
  list only shrinks.
  """
  use ExUnit.Case, async: true

  alias Slipdock.UncheckedWrites

  @root Path.expand("../..", __DIR__)
  @list Path.join(@root, "test/support/unchecked_writes.txt")

  test "no context function writes unchecked, beyond the ones listed" do
    found = UncheckedWrites.unchecked(@root)
    listed = @list |> File.read!() |> String.split("\n", trim: true)

    assert found -- listed == [],
           "these write without asking who is writing: call Slipdock.Policy.authorize/2 first"

    assert listed -- found == [],
           "these ask now (or are gone): take them off test/support/unchecked_writes.txt"
  end

  describe "on a tree made for the purpose" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "unchecked-writes-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "lib/slipdock"))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "lib/slipdock/things.ex"), """
      defmodule Slipdock.Things do
        alias Slipdock.Repo
        alias Slipdock.Things.Store

        def unchecked(thing), do: Repo.insert(thing)
        def through_a_private(thing), do: save(thing)
        def through_another_module(thing), do: Store.put(thing)
        def piped(thing), do: thing |> save()

        def asks(thing) do
          with :ok <- Slipdock.Policy.authorize(:make_thing, thing), do: Repo.insert(thing)
        end

        def asks_through_a_private(thing), do: if(allowed(thing), do: save(thing))
        def reads(id), do: Repo.get(Thing, id)

        defp save(thing), do: Repo.update(thing)
        defp allowed(thing), do: Slipdock.Policy.authorize(:make_thing, thing) == :ok
      end
      """)

      # Its own check doesn't cover the caller above: that door trusts this one.
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
               "Slipdock.Things.piped/1",
               "Slipdock.Things.through_a_private/1",
               "Slipdock.Things.through_another_module/1",
               "Slipdock.Things.unchecked/1"
             ]
    end
  end
end
