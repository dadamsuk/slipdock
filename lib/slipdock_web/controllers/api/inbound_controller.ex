defmodule SlipdockWeb.API.InboundController do
  @moduledoc """
  `POST /api/inbound/email`: one message from the Cloudflare Email Worker
  (`cloudflare/inbound-email/`), as raw MIME (W-1933).

  The request carries:

    * `X-Slipdock-Timestamp` — Unix seconds when the Worker signed it
    * `X-Slipdock-Signature` — hex HMAC-SHA256 of `timestamp <> "." <> body`,
      keyed with `SLIPDOCK_INBOUND_SECRET` (or the previous secret, while it
      is rotated)
    * `X-Envelope-To` and `X-Envelope-From` — the SMTP envelope

  The answer is the Worker's whole contract:

    * **202** — handled (or automatic mail, ignored on purpose: `"dropped"`);
      **200** — already handled, nothing new written
    * **4xx** with `{"reject": "…"}` — refused; the Worker bounces the mail
      with that reason
    * **401** — the signature is wrong or stale: a configuration problem,
      which the Worker treats as a temporary failure rather than a bounce
    * **404** — inbound mail is switched off on this server
    * **5xx** — try again later
  """
  use SlipdockWeb, :controller

  alias Slipdock.Inbound

  # Cloudflare caps inbound mail at 25 MiB; a little over that, for the
  # Worker's own framing, and anything bigger is refused unread.
  @max_body 26 * 1024 * 1024
  @max_skew 5 * 60

  def email(conn, _params) do
    if Inbound.enabled?() do
      receive_email(conn)
    else
      conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp receive_email(conn) do
    case read_raw(conn, []) do
      {:ok, raw, conn} ->
        with :ok <- verify(conn, raw),
             {:ok, envelope_to} <- envelope_to(conn) do
          conn
          |> respond(
            Inbound.receive_message(%{
              raw: raw,
              envelope_to: envelope_to,
              envelope_from: header(conn, "x-envelope-from")
            })
          )
        else
          {:error, :signature, why} ->
            conn |> put_status(:unauthorized) |> json(%{error: why})

          {:error, :envelope} ->
            reject(conn, :bad_request, "The message has no recipient.")
        end

      {:too_large, conn} ->
        reject(conn, :request_entity_too_large, "The message is too large (over 25 MB).")

      # A body that broke off mid-read: the Worker tries again.
      {:unreadable, conn} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "could not read the message"})
    end
  end

  defp respond(conn, {:accepted, email}),
    do: conn |> put_status(:accepted) |> json(%{ok: true, id: email.id})

  # Automatic mail: handled, in that nothing will come of it, and never
  # bounced, so an auto-responder gets no answer to answer.
  defp respond(conn, {:dropped, reason, email}),
    do: conn |> put_status(:accepted) |> json(%{ok: true, id: email.id, dropped: reason})

  defp respond(conn, {:duplicate, email}),
    do: conn |> put_status(:ok) |> json(%{ok: true, id: email.id, duplicate: true})

  defp respond(conn, {:rejected, reason, _email}), do: reject(conn, :unprocessable_entity, reason)
  defp respond(conn, {:rate_limited, reason}), do: reject(conn, :too_many_requests, reason)

  defp reject(conn, status, reason),
    do: conn |> put_status(status) |> json(%{reject: reason})

  defp read_raw(conn, acc) do
    case Plug.Conn.read_body(conn, length: 1_048_576, read_length: 1_048_576) do
      {:ok, chunk, conn} -> finish(conn, [acc, chunk])
      {:more, chunk, conn} -> more(conn, [acc, chunk])
      {:error, _} -> {:unreadable, conn}
    end
  end

  defp more(conn, acc) do
    if IO.iodata_length(acc) > @max_body, do: {:too_large, conn}, else: read_raw(conn, acc)
  end

  defp finish(conn, acc) do
    if IO.iodata_length(acc) > @max_body,
      do: {:too_large, conn},
      else: {:ok, IO.iodata_to_binary(acc), conn}
  end

  defp verify(conn, raw) do
    with {:ok, timestamp} <- timestamp(conn),
         :ok <- fresh(timestamp),
         signature when is_binary(signature) <- header(conn, "x-slipdock-signature") do
      signature = String.downcase(signature)

      if Enum.any?(
           Inbound.secrets(),
           &Plug.Crypto.secure_compare(sign(&1, timestamp, raw), signature)
         ),
         do: :ok,
         else: {:error, :signature, "bad signature"}
    else
      nil -> {:error, :signature, "missing signature"}
      {:error, _, _} = error -> error
    end
  end

  @doc false
  # What the Worker computes: hex HMAC-SHA256 of "<timestamp>.<body>".
  def sign(secret, timestamp, raw) do
    :crypto.mac(:hmac, :sha256, secret, [timestamp, ".", raw]) |> Base.encode16(case: :lower)
  end

  defp timestamp(conn) do
    with value when is_binary(value) <- header(conn, "x-slipdock-timestamp"),
         {_, ""} <- Integer.parse(value) do
      {:ok, value}
    else
      _ -> {:error, :signature, "missing or malformed timestamp"}
    end
  end

  defp fresh(timestamp) do
    if abs(System.system_time(:second) - String.to_integer(timestamp)) <= @max_skew,
      do: :ok,
      else: {:error, :signature, "stale timestamp"}
  end

  defp envelope_to(conn) do
    case header(conn, "x-envelope-to") do
      nil -> {:error, :envelope}
      "" -> {:error, :envelope}
      to -> {:ok, to}
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> String.trim(value)
      [] -> nil
    end
  end
end
