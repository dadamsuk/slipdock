defmodule Slipdock.Wiki.Meld do
  @moduledoc """
  Meld Encrypt's ciphertext as the server sees it: something to recognise,
  keep byte for byte, and keep out of search — never something to decrypt.
  Encrypting and decrypting happen in the browser (`assets/js/meld.js`) and
  the CLI, so the passphrase and the plaintext never reach this side.

  The format is written up on the wiki (W-1656, "Meld Encrypt format"). An
  inline block is one line: `🔐β 💡hint💡<base64> 🔐`, or wrapped in `%%`
  to hide it in Obsidian's reading view; `α` and a bare `🔐` are the two
  older versions. A whole encrypted note is a separate `.mdenc` file.
  """

  # Kept in step with INLINE in assets/js/meld.js.
  @inline ~r/(%%)?🔐(β |α | )(?:💡([^💡\n]*)💡)?([A-Za-z0-9+\/=]*) 🔐(%%)?/u

  @note_extensions [".mdenc", ".encrypted"]

  @doc "The regex for one inline block."
  def inline, do: @inline

  @doc "True when the text holds at least one inline block."
  def encrypted?(text) when is_binary(text), do: Regex.match?(@inline, text)
  def encrypted?(_), do: false

  @doc """
  Each block in the text, in order: `%{text, version, hint, base64, visible}`.
  """
  def blocks(text) when is_binary(text) do
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

  def blocks(_), do: []

  @doc """
  The text with every block replaced: by `replacement` when it is a string,
  or by what it returns for the block when it is a function. Search and
  excerpts use it, so ciphertext is never indexed or shown as noise.
  """
  def replace(text, replacement \\ "🔒")

  def replace(text, replacement) when is_binary(text) and is_binary(replacement),
    do: Regex.replace(@inline, text, replacement)

  def replace(text, fun) when is_binary(text) and is_function(fun, 1) do
    Regex.replace(@inline, text, fn whole, _, _, _, _, _ -> fun.(hd(blocks(whole))) end)
  end

  def replace(text, _), do: text

  @doc """
  The text as a listing or the search index should see it: each block a 🔒,
  and a block cut off at the end of an excerpt (`substr` of the body) gone
  too, rather than left as a run of base64.
  """
  def conceal(text, replacement \\ "🔒")

  def conceal(text, replacement) when is_binary(text) do
    text
    |> replace(replacement)
    |> String.replace(~r/(%%)?🔐[βα] (💡[^💡\n]*💡)?[A-Za-z0-9+\/=]*\z/u, replacement)
  end

  def conceal(text, _), do: text

  @doc "True for a file name Meld writes whole encrypted notes to."
  def note_file?(name) when is_binary(name),
    do: String.downcase(Path.extname(name)) in @note_extensions

  def note_file?(_), do: false

  @doc """
  A whole-note file's header, `%{version, hint}`, or nil when it is not one
  Meld wrote (or a version it does not know).
  """
  def parse_note(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"version" => v, "encodedData" => data} = note}
      when v in ["1.0", "2.0"] and is_binary(data) ->
        %{version: v, hint: note["hint"] || ""}

      _ ->
        nil
    end
  end

  def parse_note(_), do: nil

  defp version("β "), do: 2
  defp version("α "), do: 1
  defp version(_), do: 0
end
