defmodule SlipdockWeb.ByteRangeTest do
  use ExUnit.Case, async: true

  alias SlipdockWeb.ByteRange

  test "a bare recording or raster image type may be shown inline" do
    assert ByteRange.inline_type("audio/mpeg") == "audio/mpeg"
    assert ByteRange.inline_type("Audio/OGG; codecs=opus") == "audio/ogg"
    assert ByteRange.inline_type("video/webm") == "video/webm"
    assert ByteRange.inline_type("image/png") == "image/png"
  end

  test "anything else is bytes to download" do
    for type <- [
          "text/html",
          "text/javascript",
          "application/javascript",
          "image/svg+xml",
          "audio/x, text/html",
          "audio/x text/html",
          "audio/",
          "audio/x\nhtml",
          "",
          nil
        ] do
      assert ByteRange.inline_type(type) == "application/octet-stream", inspect(type)
    end
  end
end
