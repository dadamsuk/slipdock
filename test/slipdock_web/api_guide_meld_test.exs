defmodule SlipdockWeb.APIGuideMeldTest do
  @moduledoc """
  What the agent guide says about Meld-encrypted notes (W-103 R6): that the
  server only holds ciphertext, that an agent encrypts and decrypts with the
  CLI rather than by sending plaintext through the API, and how the owner
  purges revisions that still hold it.
  """
  use Slipdock.DataCase, async: true

  setup do
    %{guide: SlipdockWeb.APIGuide.markdown() |> String.split() |> Enum.join(" ")}
  end

  test "an agent is told to do it with the CLI, never with the plaintext over the API",
       %{guide: guide} do
    assert guide =~ "### Encrypted notes (Meld Encrypt)"
    assert guide =~ "Don't decrypt or encrypt by hand through the API"
    assert guide =~ "slipdock page encrypt W-31 --section Keys"
    assert guide =~ "slipdock page decrypt W-31 --in-place"
    assert guide =~ "$SLIPDOCK_MELD_PASSPHRASE"
  end

  test "the purge is described as the owner-only, ids-only write it is", %{guide: guide} do
    assert guide =~ "GET /api/pages/W-31/revisions?bodies=all"
    assert guide =~ ~s|POST /api/pages/W-31/revisions/purge {"ids": [..]}|
    assert guide =~ "so it is owner-only"
  end
end
