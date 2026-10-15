defmodule Slipdock.Wiki.EmbedsTest do
  @moduledoc """
  Sharing a page shares the files it embeds (#832), but only the embeds
  somebody who could see the file wrote there.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.{Embeds, Files}

  setup do
    owner = user_fixture("owner@example.com")
    sharee = user_fixture("sharee@example.com")
    board = board_fixture(%{"name" => "Owner's"}, owner: owner)
    {:ok, attachments} = Wiki.create_folder(board, %{"name" => "attachments"})

    path = Path.join(System.tmp_dir!(), "emb-#{System.unique_integer([:positive])}")
    File.write!(path, "bytes")
    {:ok, image} = Files.create(board, %{name: "diagram.png", folder_id: attachments.id}, path)
    {:ok, secret} = Files.create(board, %{name: "secret.png", folder_id: attachments.id}, path)

    page =
      page_fixture(board, %{"title" => "Shared", "body" => "Look: ![[diagram.png]]"}, user: owner)

    %{owner: owner, sharee: sharee, board: board, image: image, secret: secret, page: page}
  end

  defp share(page, user, level, owner), do: {:ok, _} = Access.grant(page, user, level, owner)

  test "a reader of a shared page reaches the file it embeds, not the board's others",
       %{owner: owner, sharee: sharee, page: page, image: image, secret: secret} do
    refute Access.can_read?(Access.file_permission(sharee, image))
    refute Embeds.reaches?(sharee, page, image)

    share(page, sharee, "read", owner)

    assert Embeds.reaches?(sharee, page, image)
    refute Embeds.reaches?(sharee, page, secret)
    assert Embeds.files(page, page.body) |> Enum.map(& &1.id) == [image.id]
  end

  test "a file the page only links is not passed on",
       %{owner: owner, sharee: sharee, page: page, image: image} do
    {:ok, page} = Wiki.update_page(page, %{"body" => "See [[diagram.png]]"}, user: owner)
    share(page, sharee, "read", owner)

    refute Embeds.reaches?(sharee, page, image)
  end

  test "an embed inside code is not an embed", %{
    owner: owner,
    sharee: sharee,
    page: page,
    image: image
  } do
    {:ok, page} = Wiki.update_page(page, %{"body" => "`![[diagram.png]]`"}, user: owner)
    share(page, sharee, "read", owner)

    refute Embeds.reaches?(sharee, page, image)
  end

  test "a sharee who edits the page can't embed their way into the owner's other files",
       %{owner: owner, sharee: sharee, page: page, image: image, secret: secret} do
    share(page, sharee, "write", owner)

    {:ok, page} =
      Wiki.update_page(page, %{"body" => "![[diagram.png]] ![[secret.png]]"}, user: sharee)

    # The owner's embed still stands; the sharee's own does not.
    assert Embeds.reaches?(sharee, page, image)
    refute Embeds.reaches?(sharee, page, secret)

    # Once somebody who can see the file saves the page with it, it counts.
    {:ok, page} =
      Wiki.update_page(page, %{"body" => page.body <> "\n"}, user: owner, via: "api")

    assert Embeds.reaches?(sharee, page, secret)
  end

  test "an embed taken out of the page is no longer passed on",
       %{owner: owner, sharee: sharee, page: page, image: image} do
    share(page, sharee, "write", owner)
    {:ok, page} = Wiki.update_page(page, %{"body" => "Gone"}, user: sharee)

    refute Embeds.reaches?(sharee, page, image)
  end

  test "an archived page or file, or nobody signed in, reaches nothing",
       %{owner: owner, sharee: sharee, page: page, image: image} do
    share(page, sharee, "read", owner)

    refute Embeds.reaches?(nil, page, image)
    refute Embeds.reaches?(sharee, nil, image)
    refute Embeds.reaches?(sharee, %{page | archived_at: DateTime.utc_now()}, image)
    refute Embeds.reaches?(sharee, page, %{image | archived_at: DateTime.utc_now()})
  end

  test "file_target?/1 tells a file from a page" do
    assert Embeds.file_target?("diagram.png")
    assert Embeds.file_target?("Report.PDF")
    refute Embeds.file_target?("Retry policy")
    refute Embeds.file_target?("Notes.md")
    refute Embeds.file_target?("v1.2 release notes and more")
  end

  test "page_param/1 finds the page ?page= names, and nothing for anything else",
       %{page: page} do
    assert Embeds.page_param(%{"page" => "#{page.id}"}).id == page.id
    assert Embeds.page_param(%{"page" => "x1"}) == nil
    assert Embeds.page_param(%{"page" => "0"}) == nil
    assert Embeds.page_param(%{}) == nil
  end
end
