defmodule SlipdockWeb.BoardLive.CardComponent.RepeatEvents do
  @moduledoc """
  The card panel's events on a repeating card: the Repeat… form, with what
  the rule would do shown before it is saved, and skipping, pausing or
  stopping the series.

  `BoardLive.CardComponent.handle_event/3` hands these over once it has
  decided the reader may do them. The clauses run in the component's own
  process, with its socket, as they did when they were its own.
  """
  use SlipdockWeb.WikiLive.Events

  import SlipdockWeb.BoardLive.Helpers

  alias SlipdockWeb.BoardLive.CardComponent.State
  alias SlipdockWeb.Dates

  # Repeat… (W-1802): a series on the card, set from presets or a rule of
  # one's own, with what it would do shown before it is saved.
  def handle_event("edit_repeat", _, socket) do
    %{card: card, current_user: user} = socket.assigns
    series = card.recurrence
    zone = (series && series.timezone) || Slipdock.Timezones.of(user)
    ref = card.due_date || Slipdock.Timezones.today(zone)
    presets = Slipdock.Recurrence.presets(ref)
    params = repeat_params(series, presets)

    {:noreply, assign(socket, repeat: repeat_state(params, presets, zone, ref))}
  end

  def handle_event(
        "repeat_change",
        %{"repeat" => params},
        %{assigns: %{repeat: %{} = r}} = socket
      ),
      do: {:noreply, assign(socket, repeat: repeat_state(params, r.presets, r.zone, r.ref))}

  def handle_event("repeat_change", _, socket), do: {:noreply, socket}

  def handle_event("cancel_repeat", _, socket), do: {:noreply, assign(socket, repeat: nil)}

  def handle_event("save_repeat", %{"repeat" => params}, %{assigns: %{repeat: %{} = r}} = socket) do
    %{card: card, current_user: user} = socket.assigns

    case Slipdock.Recurrence.set(card, repeat_attrs(params, r.zone), user) do
      {:ok, _} ->
        {:noreply, socket |> assign(repeat: nil) |> State.reload()}

      {:error, message} ->
        state = repeat_state(params, r.presets, r.zone, r.ref)
        {:noreply, assign(socket, repeat: %{state | error: repeat_error(message)})}
    end
  end

  def handle_event("save_repeat", _, socket), do: {:noreply, socket}

  def handle_event("skip_repeat", _, socket) do
    case Slipdock.Recurrence.skip(socket.assigns.card) do
      {:ok, _} -> {:noreply, State.reload(socket)}
      {:error, message} when is_binary(message) -> {:noreply, notice(socket, :error, message)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("pause_repeat", _, socket) do
    %{card: card, current_user: user} = socket.assigns

    if series = card.recurrence,
      do: Slipdock.Recurrence.set(card, %{"paused" => not series.paused}, user)

    {:noreply, State.reload(socket)}
  end

  def handle_event("stop_repeat", _, socket) do
    Slipdock.Recurrence.stop(socket.assigns.card)
    {:noreply, socket |> assign(repeat: nil) |> State.reload()}
  end

  # What the Repeat… form opens with: the third preset at seven for a card
  # with no series, the series' own rule and settings for one that has one.
  defp repeat_params(nil, presets),
    do: %{"preset" => elem(Enum.at(presets, 2), 0), "custom" => "", "at" => "07:00"}

  defp repeat_params(s, presets) do
    preset_rules = Enum.map(presets, &elem(&1, 0))

    %{
      "preset" => if(Enum.member?(preset_rules, s.rule), do: s.rule, else: "custom"),
      "custom" => if(Enum.member?(preset_rules, s.rule), do: "", else: s.rule),
      "at" => Dates.time(s.create_at),
      "lead_days" => to_string(s.lead_days),
      "on_missed" => s.on_missed,
      "ends" => s.ends,
      "ends_on" => s.ends_on && Date.to_iso8601(s.ends_on),
      "count" => s.count && to_string(s.count)
    }
  end

  # The Repeat… form's state: what was typed, and what it would do.
  defp repeat_state(params, presets, zone, ref) do
    rule = repeat_rule(params)

    {preview, error} =
      case Slipdock.Recurrence.describe(rule, params["at"], zone, ref) do
        {:ok, preview} -> {preview, nil}
        {:error, message} -> {nil, repeat_error(message)}
      end

    %{
      form: to_form(params, as: :repeat),
      presets: presets,
      zone: zone,
      ref: ref,
      preview: preview,
      error: error
    }
  end

  defp repeat_rule(%{"preset" => "custom"} = params), do: params["custom"]
  defp repeat_rule(params), do: params["preset"]

  defp repeat_attrs(params, zone) do
    ends = params["ends"] || "never"

    %{
      "rule" => repeat_rule(params),
      "at" => params["at"],
      "timezone" => zone,
      "lead_days" => blank_nil(params["lead_days"]) || 0,
      "on_missed" => params["on_missed"] || "bump",
      "ends" => ends,
      "ends_on" => if(ends == "on", do: blank_nil(params["ends_on"])),
      "count" => if(ends == "after", do: blank_nil(params["count"]))
    }
  end

  defp blank_nil(""), do: nil
  defp blank_nil(v), do: v

  defp repeat_error(message) when is_binary(message), do: message

  defp repeat_error(%Ecto.Changeset{} = cs), do: field_errors(cs)
end
