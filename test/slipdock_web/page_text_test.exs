defmodule SlipdockWeb.PageTextTest do
  use ExUnit.Case, async: true

  alias SlipdockWeb.PageText

  # The shape of #3146: a code that is in the session token, not the page.
  @html """
  <html><head><style>.w-31 { color: red }</style></head>
  <body>
    <div data-phx-session="SFMyNTY.g2gDW-31aAJtAAAA" id="phx-1">
      <a href="/pages/W-31">Retry policy</a>
      <p>Card #120 and   W-310</p>
      <script>window.code = "W-31"</script>
    </div>
  </body></html>
  """

  describe "text/1" do
    test "keeps what a person reads, without attributes, scripts or styles" do
      assert PageText.text(@html) == "Retry policy Card #120 and W-310"
    end
  end

  describe "mentions?/2" do
    test "matches the whole token only" do
      assert PageText.mentions?("see W-31.", "W-31")
      assert PageText.mentions?("W-31", "W-31")
      assert PageText.mentions?("(#12)", "#12")
      refute PageText.mentions?("see W-310", "W-31")
      refute PageText.mentions?("AW-31", "W-31")
      refute PageText.mentions?("#120", "#12")
      refute PageText.mentions?("#12-3", "#12")
    end

    test "takes a token with regex characters as written" do
      assert PageText.mentions?("a (b) c", "(b)")
      refute PageText.mentions?("a xbx c", ".b.")
    end
  end

  describe "refute_mentions/2 and assert_mentions/2" do
    test "a code only in the markup is not on the page" do
      assert PageText.refute_mentions(@html, "W-31") == :ok
      assert PageText.assert_mentions(@html, "W-310") == :ok
    end

    test "a code in the text fails the refute, saying what the page reads" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          PageText.refute_mentions(@html, "#120")
        end

      assert error.message =~ ~s(not to show "#120")
      assert error.message =~ "Retry policy Card #120"
    end

    test "a code missing from the text fails the assert" do
      assert_raise ExUnit.AssertionError, ~r/to show "W-31"/, fn ->
        PageText.assert_mentions(@html, "W-31")
      end
    end
  end
end
