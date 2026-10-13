defmodule SlipdockCLI.Meld do
  @moduledoc false

  # Meld Encrypt's format (the Obsidian plugin), read and written on this
  # machine with Erlang's :crypto, so `page encrypt|decrypt` never sends a
  # passphrase or a plaintext to the server (W-103 R6.8). The same format as
  # assets/js/meld.js, written up on the wiki as W-1656:
  #
  #   🔐β 💡hint💡<base64> 🔐       or the same between %% … %% (hidden)
  #   β  v2: PBKDF2-SHA512, 210000 rounds, 16-byte salt; AES-256-GCM, 16-byte
  #      iv; base64 of iv ‖ salt ‖ ciphertext ‖ tag. The one written.
  #   α  v1: PBKDF2-SHA256, 1000 rounds, a fixed salt; iv ‖ ciphertext ‖ tag.
  #      (none) v0: key SHA-256(passphrase), a fixed 12-byte iv.

  @inline ~r/(%%)?🔐(β |α | )(?:💡([^💡\n]*)💡)?([A-Za-z0-9+\/=]*) 🔐(%%)?/u

  @v1_salt "XHWnDAT6ehMVY2zD"
  @v0_iv <<196, 190, 240, 190, 188, 78, 41, 132, 15, 220, 84, 211>>
  @tag 16

  @doc "Each block in the text: `%{text, version, hint, base64, visible}`."
  def blocks(text) do
    @inline
    |> Regex.scan(text)
    |> Enum.map(fn [whole, hidden, marker, hint, base64 | _] ->
      %{
        text: whole,
        version: version(marker),
        hint: hint,
        base64: base64,
        visible: hidden == ""
      }
    end)
  end

  def encrypted?(text), do: Regex.match?(@inline, text)

  @doc "Nil, or why a hint can't be used: it would break the format."
  def check_hint(hint) when is_binary(hint) do
    if String.contains?(hint, ["💡", "🔐", "\n"]),
      do: "a hint can't hold 💡, 🔐 or a line break"
  end

  def check_hint(_), do: nil

  @doc "Nil, or why this text can't be encrypted as it stands."
  def refuse_encrypt(text) do
    cond do
      String.trim(text) == "" -> "there is nothing to encrypt"
      encrypted?(text) -> "it holds encrypted text already: decrypt it first"
      true -> nil
    end
  end

  @doc "A version 2 block, as Meld writes one."
  def encrypt_block(plaintext, passphrase, hint \\ "", visible \\ true) do
    salt = :crypto.strong_rand_bytes(16)
    iv = :crypto.strong_rand_bytes(16)
    key = :crypto.pbkdf2_hmac(:sha512, passphrase, salt, 210_000, 32)

    {sealed, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", @tag, true)

    base64 = Base.encode64(iv <> salt <> sealed <> tag)
    open = if visible, do: "🔐β ", else: "%%🔐β "
    close = if visible, do: " 🔐", else: " 🔐%%"
    open <> if(hint in [nil, ""], do: "", else: "💡#{hint}💡") <> base64 <> close
  end

  @doc "`{:ok, plaintext}`, or `:error` for a wrong passphrase or damaged text."
  def decrypt_block(%{version: version, base64: base64}, passphrase) do
    with {:ok, bytes} <- Base.decode64(base64),
         {key, iv, sealed} <- unpack(version, bytes, passphrase),
         true <- byte_size(sealed) >= @tag do
      body = binary_part(sealed, 0, byte_size(sealed) - @tag)
      tag = binary_part(sealed, byte_size(sealed) - @tag, @tag)

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, body, "", tag, false) do
        plain when is_binary(plain) -> if String.valid?(plain), do: {:ok, plain}, else: :error
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  def decrypt_block(text, passphrase) when is_binary(text) do
    case blocks(text) do
      [%{text: ^text} = block] -> decrypt_block(block, passphrase)
      _ -> :error
    end
  end

  @doc """
  The text with each block decrypted in place. `{:ok, text}`, or
  `{:error, count}` with how many blocks the passphrase did not open.
  """
  def decrypt_all(text, passphrase) do
    opened = Map.new(blocks(text), &{&1.text, decrypt_block(&1, passphrase)})
    failed = Enum.count(opened, fn {_, result} -> result == :error end)

    if failed > 0 do
      {:error, failed}
    else
      {:ok, Regex.replace(@inline, text, fn whole, _, _, _, _, _ -> elem(opened[whole], 1) end)}
    end
  end

  @doc """
  The text as one block, the whitespace around it kept outside so a section
  still ends where it did.
  """
  def encrypt_text(text, passphrase, hint \\ "") do
    [lead, core, trail] = split_space(text)
    lead <> encrypt_block(core, passphrase, hint) <> trail
  end

  defp split_space(text) do
    trimmed = String.trim(text)

    case :binary.match(text, trimmed) do
      {at, len} when trimmed != "" ->
        [
          binary_part(text, 0, at),
          trimmed,
          binary_part(text, at + len, byte_size(text) - at - len)
        ]

      _ ->
        ["", text, ""]
    end
  end

  defp unpack(2, <<iv::binary-16, salt::binary-16, sealed::binary>>, passphrase),
    do: {:crypto.pbkdf2_hmac(:sha512, passphrase, salt, 210_000, 32), iv, sealed}

  defp unpack(1, <<iv::binary-16, sealed::binary>>, passphrase),
    do: {:crypto.pbkdf2_hmac(:sha256, passphrase, @v1_salt, 1000, 32), iv, sealed}

  defp unpack(0, sealed, passphrase), do: {:crypto.hash(:sha256, passphrase), @v0_iv, sealed}
  defp unpack(_, _, _), do: :error

  defp version("β "), do: 2
  defp version("α "), do: 1
  defp version(_), do: 0

  ## The passphrase ------------------------------------------------------------
  #
  # From --passphrase-file or $SLIPDOCK_MELD_PASSPHRASE when there is no one
  # at a terminal, otherwise asked for with the echo off. Never logged,
  # never sent.

  @doc "`{:ok, passphrase}` or `{:error, why}`."
  def passphrase(o, opts \\ []) do
    cond do
      o[:passphrase_file] ->
        case File.read(o[:passphrase_file]) do
          {:ok, text} ->
            nonempty(text |> String.split(["\r\n", "\n"], parts: 2) |> hd())

          {:error, reason} ->
            {:error, "can't read #{o[:passphrase_file]}: #{:file.format_error(reason)}"}
        end

      env = System.get_env("SLIPDOCK_MELD_PASSPHRASE") ->
        nonempty(env)

      true ->
        ask(opts[:twice] == true)
    end
  end

  defp nonempty(""), do: {:error, "the passphrase is empty"}
  defp nonempty(p), do: {:ok, p}

  defp ask(twice) do
    first = prompt("Passphrase: ")

    cond do
      first in [nil, ""] ->
        {:error, "no passphrase given"}

      twice and prompt("Passphrase again: ") != first ->
        {:error, "the two passphrases don't match"}

      true ->
        {:ok, first}
    end
  end

  defp prompt(label) do
    IO.write(:stderr, label)
    echo(false)

    try do
      case IO.gets("") do
        line when is_binary(line) ->
          String.trim_trailing(line, "\n") |> String.trim_trailing("\r")

        _ ->
          nil
      end
    after
      echo(true)
      IO.write(:stderr, "\n")
    end
  end

  # stty acts on the terminal, so it reads it from /dev/tty; where there is
  # none (Windows, a pipe) the passphrase shows as it is typed, and the
  # file or the environment variable is the way to avoid that.
  defp echo(on) do
    if match?({:unix, _}, :os.type()) and File.exists?("/dev/tty") do
      :os.cmd(~c"stty #{if on, do: "echo", else: "-echo"} < /dev/tty 2>/dev/null")
    end

    :ok
  end
end
