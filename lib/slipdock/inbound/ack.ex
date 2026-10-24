defmodule Slipdock.Inbound.Ack do
  @moduledoc """
  The acknowledgement (#1249): one short email back, with the link, when a
  person's mail has made a card or a page. Off unless they turn it on
  (`inbound_ack`, on the Account tab, `POST /api/me/inbound`, or
  `slipdock inbound me --ack on`).

  Built so two systems can't loop by answering each other:

    * automatic mail is dropped before it gets here (`Slipdock.Inbound.Trust`
      `automatic/1`), so it is never answered;
    * the acknowledgement says `Auto-Submitted: auto-replied`, so a
      well-behaved auto-responder doesn't answer it, and comes from our own
      address, which the trust rules ignore if it comes back;
    * at most one per inbound message: `acked_at` on its `inbound_emails`
      row is claimed in one update before anything is sent, so a repeated or
      racing delivery finds it taken.
  """

  import Ecto.Query, only: [where: 3]
  import Swoosh.Email
  require Logger

  alias Slipdock.{Inbound, Mailer, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Inbound.Email

  @doc """
  Sends the acknowledgement for `email` (an accepted row that created
  something) when its owner wants one and none has gone yet. `:sent`, or
  `:skipped` when it shouldn't be; a failure to send is logged, not raised:
  the card is made either way.
  """
  @spec maybe_send(Email.t()) :: :sent | :skipped
  def maybe_send(%Email{outcome: "accepted", user_id: user_id} = email)
      when not is_nil(user_id) do
    email = Repo.preload(email, [:user, :card, :page, comment: :card])

    with %User{inbound_ack: true} = user <- email.user,
         path when is_binary(path) <- Inbound.created_path(email),
         true <- claim(email) do
      deliver(user, email, path)
    else
      _ -> :skipped
    end
  end

  def maybe_send(_email), do: :skipped

  # Exactly one caller wins the row.
  defp claim(%Email{id: id}) do
    {count, _} =
      Email
      |> where([e], e.id == ^id and is_nil(e.acked_at))
      |> Repo.update_all(set: [acked_at: DateTime.utc_now(:second)])

    count == 1
  end

  defp deliver(user, email, path) do
    url = Slipdock.Automations.Runner.base_url() <> path
    {what, where} = made(email)

    message =
      new()
      |> to({user.name || user.email, user.email})
      |> from(Mailer.from())
      |> subject("Added: #{title(email) || what}")
      |> header("Auto-Submitted", "auto-replied")
      |> header("In-Reply-To", email.message_id)
      |> header("References", email.message_id)
      |> text_body("""
      Your email made a #{what}#{where}:

      #{url}

      You get this because acknowledgements are on in your Slipdock account. Turn them off on your Account page.
      """)

    case mailer().(message) do
      {:ok, _} ->
        :sent

      {:error, reason} ->
        Logger.warning("Inbound acknowledgement not sent: #{Mailer.describe_error(reason)}")
        :sent
    end
  rescue
    error ->
      Logger.warning("Inbound acknowledgement not sent: #{Exception.message(error)}")
      :sent
  end

  # A test stands a failing mailer in here.
  defp mailer, do: Slipdock.Config.get(:inbound_ack_mailer, &Mailer.deliver_configured/1)

  defp title(%Email{card: %{title: title}}), do: title
  defp title(%Email{page: %{title: title}}), do: title
  defp title(_), do: nil

  defp made(%Email{card: %{} = card}), do: {"card", on_board(card.board_id)}
  defp made(%Email{page: %{} = page}), do: {"wiki page", on_board(page.board_id)}
  defp made(%Email{comment: %{}}), do: {"comment", ""}

  defp on_board(board_id) do
    case Repo.get(Slipdock.Boards.Board, board_id) do
      %{name: name} -> " on #{name}"
      nil -> ""
    end
  end
end
