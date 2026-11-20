defmodule SlipdockWeb.CLIInstallSigning do
  @moduledoc """
  What the CLI installers' tests (`cli_shell_install_test.exs` under `sh`,
  `cli_powershell_test.exs` under `pwsh`) share: a key of the test's own
  standing in for the release key, the CLI's bytes signed with it as a
  release is signed (#3506), and a server that answers one path wrong.
  """

  # This app, but answering one path with a body of the test's choosing: a
  # checksum that names other bytes, or a signature the release key never made.
  defmodule Answering do
    @moduledoc false
    @behaviour Plug
    def init({path, body}), do: {path, body}

    def call(%{request_path: path} = conn, {path, body}), do: Plug.Conn.send_resp(conn, 200, body)
    def call(conn, _), do: SlipdockWeb.Endpoint.call(conn, SlipdockWeb.Endpoint.init([]))
  end

  @doc "A plug that serves a SHA256SUMS naming other bytes."
  def wrong_sums,
    do: {Answering, {"/cli/SHA256SUMS", String.duplicate("0", 64) <> "  slipdock.escript\n"}}

  @doc "A plug that serves a signature no key made."
  def bad_signature,
    do:
      {Answering,
       {"/cli/slipdock.escript.sig",
        "-----BEGIN SSH SIGNATURE-----\nU1NIU0lH\n-----END SSH SIGNATURE-----\n"}}

  defp keygen, do: System.find_executable("ssh-keygen") || raise("these tests need ssh-keygen")

  @doc "Makes an ed25519 key at `path` (no passphrase) and gives its public half as `ssh-ed25519 <base64>`."
  def new_key(path) do
    {_, 0} = System.cmd(keygen(), ["-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", path])

    path
    |> Kernel.<>(".pub")
    |> File.read!()
    |> String.split(" ")
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  @doc """
  Signs `file` with the key at `key` as the release is signed (namespace
  `slipdock-cli`), into `file.sig`, where the server serves it from.
  """
  def sign(file, key) do
    File.rm(file <> ".sig")
    {_, 0} = System.cmd(keygen(), ["-q", "-Y", "sign", "-f", key, "-n", "slipdock-cli", file])
    :ok
  end

  @doc "Takes the signature beside `file` away, as on a server built from source."
  def unsign(file), do: File.rm!(file <> ".sig")
end
