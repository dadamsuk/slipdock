defmodule Slipdock.DirectoryLeaksTest do
  @moduledoc """
  A guard, in the spirit of `Slipdock.NothingPersonalTest`.

  `Accounts.list_users/0` returns every account on the server. Handed to a
  picker, an API response or a model prompt, it tells each customer of a shared
  instance every other customer's email address — which is exactly what
  happened at six call sites before `Access.visible_users/1` existed.

  The function is still needed, by the admin area and by `visible_users/1`
  itself. So rather than deleting it, this test says where it may be used, and
  a new call anywhere else has to be argued for here.
  """
  use ExUnit.Case, async: true

  # Where the unscoped list is legitimate, with the reason.
  @allowed %{
    # The scoped version falls back to it under `user_directory: :instance`.
    "lib/slipdock/access.ex" => "visible_users/1 itself",
    # Its own definition.
    "lib/slipdock/accounts.ex" => "the definition",
    # The admin's own view: the whole point is to see everybody.
    "lib/slipdock_web/live/users_live" => "the Users page",
    "lib/slipdock_web/controllers/api/admin_controller.ex" => "the admin area over HTTP",
    "lib/mix/tasks" => "command-line administration",
    "lib/slipdock/release.ex" => "command-line administration",
    "lib/slipdock/demo.ex" => "seeding a demo workspace"
  }

  test "nothing renders or prompts with the unscoped user list" do
    offences =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&offences_in/1)

    assert offences == [],
           """
           These call Accounts.list_users/0, which is every account on this server:

           #{Enum.map_join(offences, "\n", fn {file, line, text} -> "  #{file}:#{line}  #{String.trim(text)}" end)}

           Use Slipdock.Access.visible_users/1 (or visible_users_for/1 where there
           is no signed-in reader) instead. If the unscoped list really is right
           here, add the path to @allowed in this test with the reason.
           """
  end

  defp offences_in(file) do
    if allowed?(file) do
      []
    else
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> String.contains?(line, "list_users()") end)
      |> Enum.map(fn {line, number} -> {file, number, line} end)
    end
  end

  defp allowed?(file), do: Enum.any?(Map.keys(@allowed), &String.starts_with?(file, &1))
end
