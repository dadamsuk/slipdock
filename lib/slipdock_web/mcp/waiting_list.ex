defmodule SlipdockWeb.MCP.WaitingList do
  @moduledoc """
  The caller's own Waiting on you, trimmed over MCP (#2069): `update_card`'s
  `waiting_list` (`dismiss`, `undismiss`) and `update_board`'s (`mute`,
  `unmute`). It is the caller's list, not the card or the board, so it needs
  only read access to them, and it goes on its own: nothing else in the call.
  """

  alias Slipdock.Work
  alias SlipdockWeb.API.{Authorize, CardWrites, WorkController}
  alias SlipdockWeb.MCP.Args

  @doc "The `waiting_list` property of `update_card` (`card: true`) or `update_board`."
  def property(card: true),
    do: %{
      type: "string",
      enum: ["dismiss", "undismiss"],
      description:
        "Your own Waiting on you, nobody else's: dismiss takes this card off it for its " <>
          "current cause (a new cause, like a second failed job or a new wait, shows again); " <>
          "undismiss undoes it. Read access is enough. Send it on its own, with card."
    }

  def property(_),
    do: %{
      type: "string",
      enum: ["mute", "unmute"],
      description:
        "Your own Waiting on you, nobody else's: mute keeps this board's tree off it, unmute " <>
          "lifts that. The board works as before. Read access is enough. Send it on its own, " <>
          "with board."
    }

  @doc "Whether the call is a `waiting_list` one: `{:ok, action}`, `:no`, or an error."
  def action(args, key) do
    case Map.pop(args, "waiting_list") do
      {nil, _} -> :no
      {action, rest} when map_size(rest) == 1 and is_map_key(rest, key) -> {:ok, action}
      {_, _} -> {:error, "waiting_list goes on its own: send only #{key} with it"}
    end
  end

  @doc "Dismisses or undismisses a card on the caller's own list."
  def card(auth, id, action) do
    user = auth.assigns.current_user

    with {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :read)) do
      case {action, apply_card(action, user, card)} do
        {"dismiss", {:ok, item}} ->
          {:ok, %{dismissed: WorkController.item(Map.put(item, :path, Work.path(item.card)))}}

        {"undismiss", {:ok, n}} ->
          {:ok, %{undismissed: %{card_id: card.id, count: n}}}

        {_, {:error, :not_waiting}} ->
          {:error, "card ##{card.id} isn't waiting on you, so there is nothing to dismiss"}

        {_, {:error, :not_dismissed}} ->
          {:error, "you haven't dismissed card ##{card.id}"}
      end
    end
  end

  defp apply_card("dismiss", user, card), do: Work.dismiss(user, card)
  defp apply_card("undismiss", user, card), do: Work.undismiss(user, card)

  @doc "Mutes or unmutes a board's tree on the caller's own list."
  def board(auth, ref, action) do
    user = auth.assigns.current_user

    with {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :read)) do
      action |> apply_board(user, board) |> board_result(action, board)
    end
  end

  defp board_result({:ok, b}, action, _board) do
    key = if action == "mute", do: :muted, else: :unmuted
    {:ok, %{key => WorkController.board_ref(b)}}
  end

  defp board_result({:error, :not_muted}, _action, board),
    do: {:error, "board #{board.name} isn't muted for you"}

  defp apply_board("mute", user, board), do: Work.mute(user, board)
  defp apply_board("unmute", user, board), do: Work.unmute(user, board)
end
