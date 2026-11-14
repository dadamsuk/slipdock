defmodule SlipdockWeb.FolderPickerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Slipdock.Wiki.Folder
  alias SlipdockWeb.FolderPicker

  # Entries shaped as `Slipdock.Wiki.Folders.outline/1` gives them, built by
  # hand: the picker only reads them, so no board or database is needed.
  # "Design 2" shares "Design" as a string prefix but is not inside it.
  @design %Folder{id: 11, name: "Design"}
  @decisions %Folder{id: 12, name: "Decisions", parent_id: 11}
  @design_2 %Folder{id: 13, name: "Design 2"}

  @outline [
    %{folder: @design, path: "Design", depth: 0},
    %{folder: @decisions, path: "Design/Decisions", depth: 1},
    %{folder: @design_2, path: "Design 2", depth: 0}
  ]

  defp render_picker(attrs) do
    html = render_component(&FolderPicker.folder_picker/1, Keyword.merge([id: "picker"], attrs))
    {:ok, doc} = Floki.parse_fragment(html)
    doc
  end

  defp row(doc, folder), do: Floki.find(doc, "#picker [data-row][data-id='#{folder.id}']")

  defp disabled?(doc, folder) do
    assert [button] = row(doc, folder)
    Floki.attribute(button, "disabled") != []
  end

  defp toggle_label(doc) do
    doc |> Floki.find("#picker [data-toggle] [data-label]") |> Floki.text() |> String.trim()
  end

  describe "a folder being moved (exclude)" do
    test "it and everything inside it are disabled; a sibling sharing its name's prefix is not" do
      doc = render_picker(outline: @outline, exclude: @design.id, event: "move_to")

      assert disabled?(doc, @design)
      assert disabled?(doc, @decisions)
      refute disabled?(doc, @design_2)

      # A disabled row pushes nothing; an enabled one pushes the event.
      assert [design_row] = row(doc, @design)
      assert Floki.attribute(design_row, "phx-click") == []
      assert [design_2_row] = row(doc, @design_2)
      assert Floki.attribute(design_2_row, "phx-click") == ["move_to"]
    end

    test "excluding a child leaves its parent and the sibling choosable" do
      doc = render_picker(outline: @outline, exclude: @decisions.id)

      assert disabled?(doc, @decisions)
      refute disabled?(doc, @design)
      refute disabled?(doc, @design_2)
    end

    test "an id given as a string excludes the same folder" do
      doc = render_picker(outline: @outline, exclude: to_string(@design.id))

      assert disabled?(doc, @design)
      assert disabled?(doc, @decisions)
      refute disabled?(doc, @design_2)
    end

    test "nothing excluded, or an id that matches no folder, disables nothing" do
      for exclude <- [nil, 999] do
        doc = render_picker(outline: @outline, exclude: exclude)

        for folder <- [@design, @decisions, @design_2] do
          refute disabled?(doc, folder),
                 "#{folder.name} disabled with exclude #{inspect(exclude)}"
        end
      end
    end
  end

  describe "the toggle's label" do
    test "shows the selected folder's full path" do
      assert toggle_label(render_picker(outline: @outline, selected: @decisions.id)) ==
               "Design/Decisions"

      assert toggle_label(render_picker(outline: @outline, selected: to_string(@design_2.id))) ==
               "Design 2"
    end

    test "nothing selected shows the root label" do
      assert toggle_label(render_picker(outline: @outline)) == "The top of the wiki"

      assert toggle_label(render_picker(outline: @outline, root_label: "No folder")) ==
               "No folder"
    end

    test "an id that matches no folder falls back to the root label" do
      assert toggle_label(render_picker(outline: @outline, selected: 999)) ==
               "The top of the wiki"

      assert toggle_label(
               render_picker(outline: @outline, selected: 999, root_label: "No folder")
             ) ==
               "No folder"
    end
  end

  describe "an empty outline" do
    test "says there are no folders yet, and offers only the root" do
      doc = render_picker(outline: [])

      assert Floki.text(doc) =~ "No folders on this board yet."
      assert [_root] = Floki.find(doc, "#picker [data-row]")
      assert [_] = Floki.find(doc, "#picker [data-root-row]")
    end

    test "an outline with folders doesn't say so" do
      refute Floki.text(render_picker(outline: @outline)) =~ "No folders on this board yet."
    end
  end
end
