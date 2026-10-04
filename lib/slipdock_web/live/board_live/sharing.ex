defmodule SlipdockWeb.BoardLive.Sharing do
  @moduledoc """
  Handing out and taking back access from the board's panels: the board from
  its settings, a card from its panel, a saved view from the toolbar. Each
  caller decides first whether the reader may share the thing at all; this
  only does the granting, and checks a grant being revoked is the thing's own.
  """

  alias Slipdock.Access
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.{Board, Card, SavedView}

  @doc """
  Shares `target` with the email or group the share form posted, at its
  level. `groups` are the groups the reader may pick from.
  """
  def share(target, %{"level" => level} = params, groups, user) do
    subject =
      case params["group"] do
        g when g in [nil, ""] -> String.trim(params["email"] || "")
        id -> Enum.find(groups, &(to_string(&1.id) == id))
      end

    with {:ok, subject} <- subject(subject),
         {:ok, grant} <- Access.grant(target, subject, level, user) do
      {:ok, grant}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Couldn't share that."}
    end
  end

  @doc "Takes back grant `id`, if it is a grant on `target`."
  def revoke(id, target) do
    grant = Access.get_grant!(id)

    if belongs?(grant, target),
      do: Access.revoke(grant),
      else: {:error, "Couldn't remove that access."}
  end

  defp subject(""), do: {:error, "Enter an email address or pick a group."}
  defp subject(nil), do: {:error, "Enter an email address or pick a group."}
  defp subject(subject), do: {:ok, subject}

  defp belongs?(%Grant{} = grant, %Board{id: id}), do: grant.board_id == id
  defp belongs?(%Grant{} = grant, %Card{id: id}), do: grant.card_id == id
  defp belongs?(%Grant{} = grant, %SavedView{id: id}), do: grant.saved_view_id == id
end
