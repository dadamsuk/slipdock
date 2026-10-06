defmodule Slipdock.OAuth.ClientTest do
  use ExUnit.Case, async: true

  alias Slipdock.OAuth.Client

  describe "redirect_uri_registered?/2" do
    test "https must match exactly" do
      client = %Client{redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]}

      assert Client.redirect_uri_registered?(client, "https://claude.ai/api/mcp/auth_callback")
      refute Client.redirect_uri_registered?(client, "https://claude.ai/api/mcp/auth_callback/")

      refute Client.redirect_uri_registered?(
               client,
               "https://claude.ai:8443/api/mcp/auth_callback"
             )

      refute Client.redirect_uri_registered?(client, "http://claude.ai/api/mcp/auth_callback")

      refute Client.redirect_uri_registered?(
               client,
               "https://claude.ai/api/mcp/auth_callback?x=1"
             )
    end

    test "loopback http matches whatever the port, and nothing else" do
      client = %Client{redirect_uris: ["http://localhost:3118/callback", "http://[::1]/cb"]}

      assert Client.redirect_uri_registered?(client, "http://localhost:53682/callback")
      assert Client.redirect_uri_registered?(client, "http://localhost/callback")
      assert Client.redirect_uri_registered?(client, "http://[::1]:9000/cb")
      refute Client.redirect_uri_registered?(client, "http://localhost:53682/other")
      refute Client.redirect_uri_registered?(client, "http://127.0.0.1:53682/callback")
      refute Client.redirect_uri_registered?(client, "https://localhost:53682/callback")
      refute Client.redirect_uri_registered?(client, "http://evil.com:3118/callback")
    end

    test "nothing matches a missing or non-string redirect URI" do
      client = %Client{redirect_uris: ["https://example.com/cb"]}

      refute Client.redirect_uri_registered?(client, nil)
      refute Client.redirect_uri_registered?(client, ["https://example.com/cb"])
    end
  end

  test "valid_redirect_uri?/1 refuses an overlong address" do
    refute Client.valid_redirect_uri?("https://example.com/" <> String.duplicate("a", 2000))
    assert Client.valid_redirect_uri?("https://example.com/" <> String.duplicate("a", 100))
  end
end
