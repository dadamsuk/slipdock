defmodule Slipdock.Accounts.DeviceFlow do
  @moduledoc """
  Device authorization (RFC 8628): how a CLI or an agent with no browser gets
  an API token. It asks for a code, a person types that code in while signed
  in and approves it, and the client's polling then collects a token.

  Apart from the API tokens it ends in because the risks are different: the
  request is started by somebody anonymous, so each step is decided once and
  consumed once. Reached through `Slipdock.Accounts`.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Accounts
  alias Slipdock.Accounts.{DeviceAuthorization, User}

  @doc """
  Starts a device-authorization request. Returns
  `{plaintext_device_code, record}`; the client polls with the first and shows
  the record's `user_code` to a person.

  The `admin` scope is refused with `{:error, :admin_scope}`. Whoever starts a
  request is anonymous and chooses its label, so an admin-scope request is a
  code anybody could send an admin with a friendly name on it; admin tokens are
  made on the account page, by an admin, deliberately.
  """
  def request_device_authorization(attrs \\ %{}) do
    if attrs[:scope] == "admin" do
      {:error, :admin_scope}
    else
      # Cheap, and it means the table never accumulates requests nobody
      # finished with. There is no scheduled job to forget to run.
      purge_expired_device_authorizations()

      scope = if attrs[:scope] in ~w(read write), do: attrs[:scope], else: "write"

      {device_code, record} =
        DeviceAuthorization.build(Map.put(Map.new(attrs), :scope, scope))

      {device_code, Repo.insert!(record)}
    end
  end

  @doc """
  The pending request a person's typed code refers to, or nil. Approved,
  denied and expired requests are *not* findable: a code is good once.
  """
  def device_authorization_by_user_code(input) do
    case DeviceAuthorization.normalise_code(input) do
      "" ->
        nil

      code ->
        DeviceAuthorization.pending()
        |> where([d], d.user_code == ^code)
        |> Repo.one()
    end
  end

  @doc """
  Approves a pending request on `user`'s behalf, minting their token.

  The decision is made once. The update only lands on a row that is still
  pending, so two approvals racing each other — or an approval racing a
  refusal — leave the first one standing; the loser gets `{:error, :expired}`,
  as if the code had gone, which for them it has.
  """
  def approve_device_authorization(%DeviceAuthorization{} = request, %User{} = user) do
    decide_device_authorization(request, approved_at: DateTime.utc_now(:second), user_id: user.id)
  end

  @doc "Refuses a pending request. The client is told, rather than left polling."
  def deny_device_authorization(%DeviceAuthorization{} = request) do
    decide_device_authorization(request, denied_at: DateTime.utc_now(:second))
  end

  defp decide_device_authorization(request, changes) do
    query = DeviceAuthorization.pending() |> where([d], d.id == ^request.id)

    case Repo.update_all(query, set: changes) do
      {1, _} -> {:ok, Repo.get!(DeviceAuthorization, request.id)}
      _ -> {:error, :expired}
    end
  end

  @doc """
  What the polling client gets. On approval the token is minted here, once:
  the request is consumed in the same transaction, so a device code that is
  polled twice cannot yield two tokens.

  Every failure is reported as RFC 8628 names them, and an unknown code is
  `:invalid` — the same answer a wrong code gets, so polling cannot be used to
  learn which codes exist.
  """
  def poll_device_authorization(plaintext) do
    with {:ok, hashed} <- DeviceAuthorization.hash_device_code(plaintext),
         %DeviceAuthorization{} = request <-
           Repo.one(from(d in DeviceAuthorization, where: d.device_code == ^hashed)) do
      cond do
        request.denied_at -> {:error, :access_denied}
        DeviceAuthorization.expired?(request) -> {:error, :expired_token}
        is_nil(request.approved_at) -> {:error, :authorization_pending}
        true -> mint_from_device_authorization(request)
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp mint_from_device_authorization(request) do
    Repo.transaction(fn ->
      # Consume it first. Whoever deletes the row is the one who gets to mint,
      # so a client polling twice in parallel still ends up with one token.
      case Repo.delete_all(from(d in DeviceAuthorization, where: d.id == ^request.id)) do
        {1, _} ->
          user = Accounts.get_user!(request.user_id)

          {token, _row} =
            Accounts.create_api_token(user, request.client_label || "Device",
              scope: request.scope,
              scope_boards: request.scope_boards,
              expires_at: Accounts.expiry_in_days(90)
            )

          token

        _ ->
          Repo.rollback(:invalid)
      end
    end)
  end

  @doc "Clears out requests nobody finished with. Safe to call at any time."
  def purge_expired_device_authorizations do
    now = DateTime.utc_now()
    {count, _} = Repo.delete_all(from(d in DeviceAuthorization, where: d.expires_at <= ^now))
    count
  end
end
