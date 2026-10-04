defmodule Slipdock.UpdatesStub do
  @moduledoc """
  Stands in for GHCR in tests: the token, the multi-architecture index, the
  per-platform manifest and the image config, told apart by path. Turns the
  update check on for the test, and shares the stub so a LiveView's async
  check sees it too.
  """

  @doc """
  Publishes an image built from `revision` at `created` (ISO8601), or answers
  every request with `status` when given `{:status, status}`.
  """
  def publish({:status, status}) do
    enable()
    Req.Test.stub(Slipdock.Updates, &Plug.Conn.send_resp(&1, status, ""))
  end

  def publish(revision, created \\ "2099-01-01T00:00:00Z") do
    enable()

    Req.Test.stub(Slipdock.Updates, fn conn ->
      case conn.path_info do
        ["token"] ->
          Req.Test.json(conn, %{"token" => "anonymous"})

        [_v2, _owner, _name, "manifests", "latest"] ->
          Req.Test.json(conn, %{
            "manifests" => [
              %{"digest" => "sha256:attest", "platform" => %{"os" => "unknown"}},
              %{"digest" => "sha256:amd64", "platform" => %{"os" => "linux"}}
            ]
          })

        [_v2, _owner, _name, "manifests", "sha256:amd64"] ->
          Req.Test.json(conn, %{"config" => %{"digest" => "sha256:config"}})

        [_v2, _owner, _name, "blobs", "sha256:config"] ->
          Req.Test.json(conn, %{
            "config" => %{
              "Labels" => %{
                "org.opencontainers.image.revision" => revision,
                "org.opencontainers.image.created" => created
              }
            }
          })
      end
    end)
  end

  defp enable do
    previous = Application.get_env(:slipdock, :updates)
    Application.put_env(:slipdock, :updates, Keyword.put(previous, :enabled, true))
    Req.Test.set_req_test_to_shared()

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:slipdock, :updates, previous)
      Req.Test.set_req_test_to_private()
    end)
  end
end
