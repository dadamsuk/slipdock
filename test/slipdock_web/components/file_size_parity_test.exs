defmodule SlipdockWeb.FileSizeParityTest do
  # One file-size formatter (#2876): `CoreComponents.file_size/1` is
  # `Quota.humanise_bytes/1`, and the upload picker's `fileSize` in
  # `assets/js/file_picker.js` writes the same words. Both are held to the
  # same table: this side here, the JavaScript in file_picker.test.js.
  use ExUnit.Case, async: true

  alias Slipdock.Quota
  alias SlipdockWeb.CoreComponents

  @external_resource "assets/js/file_size_cases.json"
  @cases "assets/js/file_size_cases.json"
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("cases")

  test "the shared table crosses every unit's edge" do
    says = Enum.map(@cases, & &1["says"])

    for label <- ["0 B", "1023 B", "1 KB", "1 MB", "1.4 MB", "1 GB", "10 GB", ""] do
      assert label in says
    end
  end

  for %{"bytes" => bytes, "says" => says} <- @cases do
    test "#{inspect(bytes)} bytes reads #{inspect(says)}" do
      assert CoreComponents.file_size(unquote(bytes)) == unquote(says)
    end
  end

  test "a count is the same words from Quota as from file_size/1" do
    for %{"bytes" => bytes} when is_integer(bytes) and bytes >= 0 <- @cases do
      assert Quota.humanise_bytes(bytes) == CoreComponents.file_size(bytes)
    end
  end

  test "anything but a count reads as nothing" do
    assert CoreComponents.file_size(nil) == ""
    assert CoreComponents.file_size(-5) == ""
    assert CoreComponents.file_size("12") == ""
    assert CoreComponents.file_size(1.5) == ""
  end

  test "the same 1,500,000-byte file reads alike in the viewer, the picker and a card" do
    # The viewer said 1.5 MB (1000s) where the picker and a card said 1.4 MB.
    assert CoreComponents.file_size(1_500_000) == "1.4 MB"
    Code.ensure_loaded!(SlipdockWeb.FileViewer)
    Code.ensure_loaded!(SlipdockWeb.BoardLive.Helpers)
    refute function_exported?(SlipdockWeb.FileViewer, :size, 1)
    refute function_exported?(SlipdockWeb.BoardLive.Helpers, :human_size, 1)
  end
end
