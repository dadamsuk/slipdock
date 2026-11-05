defmodule SlipdockWeb.FilePickerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.CoreComponents

  defp parse(html) do
    {:ok, doc} = Floki.parse_fragment(html)
    doc
  end

  describe "file_picker/1 on a plain form" do
    test "a drop zone with a button, the input out of sight, and what it takes" do
      doc =
        parse(
          render_component(&CoreComponents.file_picker/1,
            id: "logo",
            name: "logo",
            accept: ".png,.svg"
          )
        )

      assert [_] = Floki.find(doc, "#logo[data-file-picker][phx-hook=FilePicker]")

      assert doc |> Floki.find("label[for=logo-input]") |> Floki.text() |> String.trim() ==
               "Choose file"

      assert [input] = Floki.find(doc, "input#logo-input[type=file]")
      assert Floki.attribute(input, "name") == ["logo"]
      assert Floki.attribute(input, "accept") == [".png,.svg"]
      assert Floki.attribute(input, "class") == ["file-picker-input"]

      assert doc |> Floki.find("[data-role=file-hint]") |> Floki.text() == "A .png or .svg file"
      # The row the hook fills in, hidden until a file is chosen.
      assert [_] = Floki.find(doc, "li[data-role=file][hidden]")
      assert [_] = Floki.find(doc, "[data-role=file-remove]")
    end

    test "a hint replaces the worked-out words; none when nothing is known" do
      doc =
        parse(render_component(&CoreComponents.file_picker/1, id: "f", name: "f", hint: "A CSV"))

      assert doc |> Floki.find("[data-role=file-hint]") |> Floki.text() == "A CSV"

      doc = parse(render_component(&CoreComponents.file_picker/1, id: "f", name: "f"))
      assert Floki.find(doc, "[data-role=file-hint]") == []
    end

    test "extra errors show under it and mark it" do
      doc =
        parse(
          render_component(&CoreComponents.file_picker/1,
            id: "f",
            name: "f",
            errors: ["That isn't a board export."]
          )
        )

      assert doc |> Floki.find("[data-role=file-error]") |> Floki.text() ==
               "That isn't a board export."

      assert [_] = Floki.find(doc, "#f.file-picker-error")
    end

    test "disabled disables the input and greys the button" do
      doc =
        parse(render_component(&CoreComponents.file_picker/1, id: "f", name: "f", disabled: true))

      assert [_] = Floki.find(doc, "input[type=file][disabled]")
      assert [_] = Floki.find(doc, "label.btn-disabled")
    end
  end

  describe "accepted_words/2" do
    test "from an upload's accept list and limit" do
      assert CoreComponents.accepted_words(%{
               accept: ~w(.json application/json),
               max_file_size: 8_000_000
             }) ==
               "A .json file, up to 7.6 MB"

      assert CoreComponents.accepted_words(%{accept: ".mp3,.wav,.m4a", max_file_size: 1024}) ==
               "A .mp3, .wav or .m4a file, up to 1 KB"

      assert CoreComponents.accepted_words(%{accept: :any, max_file_size: 10 * 1024 * 1024}) ==
               "Any file, up to 10 MB"
    end

    test "from a plain input's accept, and nothing for nothing" do
      assert CoreComponents.accepted_words(nil, ".png") == "A .png file"
      assert CoreComponents.accepted_words(nil, "image/*") == nil
      assert CoreComponents.accepted_words(nil, nil) == nil
    end
  end

  test "file_size/1" do
    assert CoreComponents.file_size(512) == "512 B"
    assert CoreComponents.file_size(1024) == "1 KB"
    assert CoreComponents.file_size(12_800) == "12.5 KB"
    assert CoreComponents.file_size(10 * 1024 * 1024) == "10 MB"
    assert CoreComponents.file_size(nil) == ""
  end
end
