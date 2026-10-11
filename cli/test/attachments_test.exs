defmodule SlipdockCLI.AttachmentsTest do
  @moduledoc """
  `slipdock attach`, `attachments` and `detach`: which path each asks (a
  number is a card, anything else a page), what the upload carries, and what
  is printed. The refusals end in `System.halt/1`, so they are covered on the
  server's side, in `SlipdockWeb.API.AttachmentsTest`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-attach-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp file(home, name, contents) do
    path = Path.join(home, name)
    File.write!(path, contents)
    path
  end

  defp attached(id, name, markdown),
    do:
      ~s({"attachment":{"id":#{id},"filename":"#{name}","content_type":"image/png","size":4,"url":"/attachments/#{id}/#{name}","markdown":"#{markdown}"}})

  test "attach uploads the bytes as `file` and prints the Markdown that embeds it", %{home: home} do
    serve([{201, attached(5, "shot.png", "![shot.png](/attachments/5/shot.png)")}])
    shot = file(home, "shot.png", "PNG!")

    out = capture_io(fn -> Boards.run("attach", ["12", shot], []) end)

    assert_received {:request, "POST", "/api/cards/12/attachments", body}
    assert body =~ ~s(name="file"; filename="shot.png")
    assert body =~ "content-type: application/octet-stream"
    assert body =~ "PNG!"

    assert out =~ "attached shot.png to card #12 [attachment #5]"
    assert out =~ "![shot.png](/attachments/5/shot.png)"
  end

  test "a page code goes to the page, and --name renames the file", %{home: home} do
    serve([{201, attached(6, "diagram.png", "![diagram.png](/attachments/6/diagram.png)")}])
    tmp = file(home, "tmp-123", "PNG!")

    out = capture_io(fn -> Boards.run("attach", ["W-31", tmp], name: "diagram.png") end)

    assert_received {:request, "POST", "/api/pages/W-31/attachments", body}
    assert body =~ ~s(filename="diagram.png")
    assert out =~ "attached diagram.png to page W-31"
  end

  test "several files are several uploads", %{home: home} do
    serve([
      {201, attached(1, "a.png", "![a.png](/attachments/1/a.png)")},
      {201, attached(2, "b.png", "![b.png](/attachments/2/b.png)")}
    ])

    a = file(home, "a.png", "A")
    b = file(home, "b.png", "B")

    out = capture_io(fn -> Boards.run("attach", ["12", a, b], []) end)

    assert_received {:request, "POST", "/api/cards/12/attachments", _}
    assert_received {:request, "POST", "/api/cards/12/attachments", _}
    assert out =~ "[attachment #1]" and out =~ "[attachment #2]"
  end

  test "attachments lists each file, and says so when there are none" do
    serve([
      {200,
       ~s({"attachments":[{"id":5,"filename":"shot.png","content_type":"image/png","size":2048,"url":"/attachments/5/shot.png"}]})},
      {200, ~s({"attachments":[]})}
    ])

    out = capture_io(fn -> Boards.run("attachments", ["12"], []) end)
    assert_received {:request, "GET", "/api/cards/12/attachments", _}
    assert out =~ "shot.png (image/png, 2 KB) /attachments/5/shot.png [attachment #5]"

    assert capture_io(fn -> Boards.run("attachments", ["W-31"], []) end) =~
             "no attachments on page W-31"

    assert_received {:request, "GET", "/api/pages/W-31/attachments", _}
  end

  test "detach deletes each one named" do
    serve([{200, ~s({"ok":true})}, {200, ~s({"ok":true})}])

    out = capture_io(fn -> Boards.run("detach", ["12", "5", "6"], []) end)

    assert_received {:request, "DELETE", "/api/cards/12/attachments/5", _}
    assert_received {:request, "DELETE", "/api/cards/12/attachments/6", _}
    assert out =~ "removed attachment #5 from card #12"
    assert out =~ "removed attachment #6 from card #12"
  end

  test "card shows the card's files, with the ids detach takes" do
    card = %{
      "id" => 12,
      "title" => "Has a screenshot",
      "board_id" => 3,
      "blocked_by" => [],
      "blocks" => [],
      "flags" => [],
      "tags" => [],
      "assignees" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "comments" => [],
      "urls" => [],
      "links" => [],
      "attachments" => [
        %{
          "id" => 5,
          "filename" => "shot.png",
          "content_type" => "image/png",
          "size" => 2048,
          "url" => "/attachments/5/shot.png"
        }
      ]
    }

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ "Files"
    assert out =~ "shot.png (image/png, 2 KB) /attachments/5/shot.png [attachment #5]"

    refute capture_io(fn -> Render.card(%{card | "attachments" => []}) end) =~ "Files"
  end

  test "a file's line gives its size in the unit that reads" do
    line = fn size -> Render.attachment_line(%{"filename" => "f", "size" => size}) end

    assert line.(12) =~ "12 B"
    assert line.(4096) =~ "4 KB"
    assert line.(3 * 1_048_576) =~ "3.0 MB"
  end
end
