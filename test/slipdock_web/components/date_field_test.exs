defmodule SlipdockWeb.DateFieldTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]

  alias SlipdockWeb.CoreComponents

  defmodule FormLive do
    # A form with one date in it, saved on change: what the card back does.
    use SlipdockWeb, :live_view

    def mount(_params, session, socket) do
      due = session["due"]
      {:ok, assign(socket, due: due, required: session["required"] || false, saved: [])}
    end

    def render(assigns) do
      assigns = assign(assigns, form: to_form(%{"due_date" => assigns.due}, as: :card))

      ~H"""
      <form id="f" phx-change="save" phx-submit="save">
        <.date_field
          id="due"
          field={@form[:due_date]}
          label="Due date"
          required={@required}
        />
      </form>
      <p id="saved">{inspect(@saved)}</p>
      """
    end

    def handle_event("save", %{"card" => %{"due_date" => due}}, socket) do
      {:noreply, assign(socket, due: due, saved: [due | socket.assigns.saved])}
    end
  end

  defp render_field(attrs), do: render_component(&CoreComponents.date_field/1, attrs)

  defp parse(html) do
    {:ok, doc} = Floki.parse_fragment(html)
    doc
  end

  describe "date_field/1" do
    test "a date shows in words over a native date input carrying the ISO value" do
      doc = parse(render_field(id: "d", name: "card[due_date]", value: ~D[2030-01-15]))

      assert Floki.find(doc, "#d[phx-hook=DateField].date-field.field") != []
      assert doc |> Floki.find("#d [data-role=date-text]") |> Floki.text() == "15 Jan 2030"

      assert [input] = Floki.find(doc, "#d input[type=date]")
      assert Floki.attribute(input, "name") == ["card[due_date]"]
      assert Floki.attribute(input, "value") == ["2030-01-15"]
      assert Floki.attribute(input, "id") == ["d-input"]
      assert Floki.find(doc, "#d [data-role=date-clear]") |> Floki.attribute("hidden") == []
    end

    test "with no date it says Add date (or the placeholder), and the clear button hides" do
      doc = parse(render_field(id: "d", name: "x", value: nil))
      assert doc |> Floki.find("[data-role=date-text]") |> Floki.text() == "Add date"
      assert [_] = Floki.attribute(Floki.find(doc, "#d"), "data-empty")
      assert [_] = Floki.find(doc, "[data-role=date-clear]") |> Floki.attribute("hidden")
      assert Floki.find(doc, "input[type=date]") |> Floki.attribute("value") == []

      doc = parse(render_field(id: "d", name: "x", value: "", placeholder: "No end date"))
      assert doc |> Floki.find("[data-role=date-text]") |> Floki.text() == "No end date"
    end

    test "the wrapper carries the viewer's timezone for the hook's year (#2881)" do
      doc = parse(render_field(id: "d", name: "x", value: ~D[2030-01-15]))
      assert Floki.attribute(Floki.find(doc, "#d"), "data-zone") == ["Etc/UTC"]

      # The zone is this process's, so it goes with the test.
      SlipdockWeb.Dates.put_zone("Pacific/Auckland")
      doc = parse(render_field(id: "d", name: "x", value: nil))
      assert Floki.attribute(Floki.find(doc, "#d"), "data-zone") == ["Pacific/Auckland"]
    end

    test "takes an ISO string, and ignores one that isn't a date" do
      doc = parse(render_field(name: "x", value: "2030-02-03"))
      assert doc |> Floki.find("[data-role=date-text]") |> Floki.text() == "3 Feb 2030"

      doc = parse(render_field(name: "x", value: "18/11/2026"))
      assert doc |> Floki.find("[data-role=date-text]") |> Floki.text() == "Add date"
    end

    test "required leaves the clear button out" do
      doc = parse(render_field(id: "d", name: "x", value: ~D[2030-01-15], required: true))
      assert Floki.find(doc, "[data-role=date-clear]") == []
      assert Floki.find(doc, "input[type=date][required]") != []
    end

    test "bare is field-bare; min and max pass through as ISO" do
      doc =
        parse(
          render_field(
            id: "d",
            name: "x",
            value: nil,
            bare: true,
            min: ~D[2030-01-01],
            max: "2030-12-31"
          )
        )

      assert Floki.find(doc, "#d.field-bare") != []
      assert Floki.find(doc, "#d.field") == []
      assert Floki.find(doc, "input[min='2030-01-01'][max='2030-12-31']") != []
    end

    test "an aria-label names the display with its value; disabled disables all three" do
      doc =
        parse(render_field(name: "x", value: ~D[2030-01-15], "aria-label": "Due", disabled: true))

      assert Floki.find(doc, "[data-role=date-display]") |> Floki.attribute("aria-label") ==
               ["Due: 15 Jan 2030"]

      assert length(Floki.find(doc, "[disabled]")) == 3
    end

    test "errors on a used field show under it and mark the box" do
      form =
        to_form(%{"due_date" => "2030-01-15"},
          as: :card,
          errors: [due_date: {"must be after the start", []}]
        )

      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <CoreComponents.date_field id="d" field={@form[:due_date]} />
        """)

      assert html =~ "must be after the start"
      assert parse(html) |> Floki.find("#d.input-error") != []
    end
  end

  describe "in a form" do
    test "set, change and clear post the same params a raw date input did", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, FormLive, session: %{"due" => nil})

      assert has_element?(view, "#due [data-role=date-text]", "Add date")
      assert has_element?(view, "label[for=due-display]", "Due date")

      view |> form("#f", card: %{due_date: "2030-01-15"}) |> render_change()
      assert has_element?(view, "#due [data-role=date-text]", "15 Jan 2030")
      assert has_element?(view, "#due-input[value='2030-01-15']")

      view |> form("#f", card: %{due_date: "2030-02-01"}) |> render_change()
      assert has_element?(view, "#due [data-role=date-text]", "1 Feb 2030")

      # The × empties the native input and fires change: an empty value.
      view |> form("#f", card: %{due_date: ""}) |> render_change()
      assert has_element?(view, "#due [data-role=date-text]", "Add date")
      assert has_element?(view, "#due [data-role=date-clear][hidden]")

      assert render(view) =~ ~s|[&quot;&quot;, &quot;2030-02-01&quot;, &quot;2030-01-15&quot;]|
    end

    test "a required date has no clear button and still submits", %{conn: conn} do
      {:ok, view, _} =
        live_isolated(conn, FormLive, session: %{"due" => "2030-01-15", "required" => true})

      refute has_element?(view, "#due [data-role=date-clear]")
      view |> form("#f", card: %{due_date: "2030-03-03"}) |> render_submit()
      assert has_element?(view, "#due [data-role=date-text]", "3 Mar 2030")
    end
  end
end
