defmodule SlipdockCLI.NoteTest do
  @moduledoc "`slipdock note`: a quick note, and where the server put it."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    saved = Map.new(~w(SLIPDOCK_URL SLIPDOCK_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("SLIPDOCK_TOKEN", "test-token")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  test "the words go to the server and the place comes back" do
    note = %{code: "W-9", title: "2026-10-30 15.39 Printers", vault: "Mind", location: "/Inbox"}

    System.put_env(
      "SLIPDOCK_URL",
      FakeServer.start([{201, :json.encode(%{note: note}) |> IO.iodata_to_binary()}])
    )

    out = capture_io(fn -> Wiki.run("note", ["ring", "them"], []) end)

    assert out =~ "noted W-9  2026-10-30 15.39 Printers"
    assert out =~ "in Mind /Inbox"
  end

  test "`page ai` prints the answer, and what it left out" do
    answer = %{text: "All about printers.", truncated: true, concealed: true}

    System.put_env(
      "SLIPDOCK_URL",
      FakeServer.start([{200, :json.encode(%{answer: answer}) |> IO.iodata_to_binary()}])
    )

    out = capture_io(fn -> Wiki.run("page", ["ai", "W-9", "summarise"], []) end)

    assert out =~ "All about printers."
    assert out =~ "only the start of the page"
    assert out =~ "encrypted passages were left out"
  end
end
