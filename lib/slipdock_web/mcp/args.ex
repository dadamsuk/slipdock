defmodule SlipdockWeb.MCP.Args do
  @moduledoc """
  Reading a tool's arguments, and answering in the shape `SlipdockWeb.MCP.Tool`
  expects. A client's model writes these arguments, so every mistake gets a
  sentence it can act on rather than a crash.
  """

  @doc """
  What `SlipdockWeb.API.Authorize` reads from a conn — the user and the token
  — for a call that has no conn. Visibility through MCP is then exactly what
  the HTTP API allows the same token, because it is the same check.
  """
  def auth(%{user: user, token: token}), do: %{assigns: %{current_user: user, api_token: token}}

  @doc "A required string argument, trimmed."
  def required(args, key) do
    case args[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "#{key} is required"}
          trimmed -> {:ok, trimmed}
        end

      value when is_integer(value) ->
        {:ok, to_string(value)}

      nil ->
        {:error, "#{key} is required"}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  @doc "An optional string argument; nil when absent or blank."
  def optional(args, key) do
    case args[key] do
      nil ->
        {:ok, nil}

      value when is_integer(value) ->
        {:ok, to_string(value)}

      value when is_binary(value) ->
        {:ok, if(String.trim(value) == "", do: nil, else: String.trim(value))}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  @doc "An optional boolean argument."
  def boolean(args, key, default \\ nil) do
    case args[key] do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{key} must be true or false"}
    end
  end

  @doc "An optional positive integer, capped at `max`."
  def limit(args, key, default, max) do
    case args[key] do
      nil -> {:ok, default}
      n when is_integer(n) and n > 0 -> {:ok, min(n, max)}
      _ -> {:error, "#{key} must be a positive whole number"}
    end
  end

  @doc "A required id: a whole number, or a string of one (`\"#129\"` too)."
  def id(args, key) do
    case args[key] do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(s |> String.trim() |> String.trim_leading("#")) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "#{key} must be a card number, like 129"}
        end

      nil ->
        {:error, "#{key} is required"}

      _ ->
        {:error, "#{key} must be a card number, like 129"}
    end
  end

  @doc """
  An optional list of ids — card numbers, checklist item ids — each a whole
  number or a string of one (`"#129"` too). A single id counts as a list of one.
  """
  def ids(args, key) do
    case args[key] do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
          case id(%{key => value}, key) do
            {:ok, n} -> {:cont, {:ok, acc ++ [n]}}
            {:error, _} -> {:halt, {:error, "#{key} must be a list of numbers, like [129]"}}
          end
        end)

      single ->
        case id(%{key => single}, key) do
          {:ok, n} -> {:ok, [n]}
          {:error, _} -> {:error, "#{key} must be a list of numbers, like [129]"}
        end
    end
  end

  @doc """
  The API's `{:error, status, message}` refusals, as a tool's error text. A
  thing that is not there, or not the reader's to see, reads the same.
  """
  def refusal({:error, %Ecto.Changeset{} = changeset}) do
    case Slipdock.Quota.limit_kind(changeset) do
      nil ->
        {:error, "not saved: " <> describe(changeset)}

      kind ->
        # The one failure an unattended client must not retry: nothing it can
        # change about the request makes room on the account.
        {:error,
         "#{Slipdock.Quota.error_code(kind)}: #{describe(changeset)} Don't retry, and don't " <>
           "work around it with a page or a different title: the account is at its limit " <>
           "for #{Slipdock.Quota.label(kind)}. Tell the person; archiving something finished " <>
           "with frees room."}
    end
  end

  def refusal({:error, :conflict, %{content_hash: hash}}),
    do:
      {:error,
       "conflict: the page has changed since you read it (now content_hash #{hash}). " <>
         "Read it again with read_page, merge your change into what is there, and write " <>
         "with the new hash."}

  def refusal({:error, :payment_required, code, message}),
    do: {:error, "#{code}: #{message} Don't retry: the account is at its limit. Tell the person."}

  def refusal({:error, :not_found, what}), do: {:error, "no #{what} you can see matches that"}
  def refusal({:error, _status, message}) when is_binary(message), do: {:error, message}
  def refusal({:error, message}) when is_binary(message), do: {:error, message}
  def refusal(other), do: other

  defp describe(changeset) do
    changeset
    |> SlipdockWeb.API.JSON.errors()
    |> Enum.map_join(" ", fn {field, messages} ->
      Enum.map_join(List.wrap(messages), " ", fn m ->
        if field == :base, do: "#{m}.", else: "#{field} #{m}."
      end)
    end)
  end

  @doc "An optional list of strings; a single string counts as a list of one."
  def strings(args, key) do
    case args[key] do
      nil ->
        {:ok, nil}

      s when is_binary(s) ->
        {:ok, [s]}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "#{key} must be a list of strings"}

      _ ->
        {:error, "#{key} must be a list of strings"}
    end
  end
end
