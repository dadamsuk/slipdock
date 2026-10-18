defmodule Slipdock.TimezonesTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Accounts, Timezones}

  describe "valid?/1" do
    test "knows canonical zones, links and UTC" do
      assert Timezones.valid?("Europe/London")
      assert Timezones.valid?("America/New_York")
      assert Timezones.valid?("US/Eastern")
      assert Timezones.valid?("Etc/UTC")
    end

    test "refuses what isn't a zone" do
      refute Timezones.valid?("Mars/Olympus_Mons")
      refute Timezones.valid?("")
      refute Timezones.valid?(nil)
      refute Timezones.valid?(42)
    end
  end

  test "all/0 is sorted canonical names with UTC among them" do
    zones = Timezones.all()
    assert "Europe/London" in zones
    assert "Etc/UTC" in zones
    assert zones == Enum.sort(zones)
    assert length(zones) > 300
    assert "US/Eastern" in Timezones.options("US/Eastern")
    assert Timezones.options("Europe/London") == zones
  end

  test "of/1 defaults to Etc/UTC" do
    assert Timezones.of(%{timezone: nil}) == "Etc/UTC"
    assert Timezones.of(%{timezone: ""}) == "Etc/UTC"
    assert Timezones.of(%{timezone: "Asia/Tokyo"}) == "Asia/Tokyo"
    assert Timezones.of(user_fixture()) == "Etc/UTC"
  end

  describe "to_utc/3" do
    test "an ordinary time, winter and summer" do
      assert Timezones.to_utc(~D[2027-01-11], ~T[07:00:00], "Europe/London") ==
               ~U[2027-01-11 07:00:00Z]

      assert Timezones.to_utc(~D[2027-07-12], ~T[07:00:00], "Europe/London") ==
               ~U[2027-07-12 06:00:00Z]

      assert Timezones.to_utc(~D[2027-07-12], ~T[07:00:00], "America/New_York") ==
               ~U[2027-07-12 11:00:00Z]
    end

    test "a time in the spring-forward gap is the moment after it" do
      # 28 March 2027: London goes 01:00 GMT -> 02:00 BST, so 01:30 never happens.
      assert Timezones.to_utc(~D[2027-03-28], ~T[01:30:00], "Europe/London") ==
               ~U[2027-03-28 01:00:00Z]
    end

    test "a time that happens twice in the autumn is the first" do
      # 7 November 2027: New York repeats 01:00-02:00; the first is still EDT (-4).
      assert Timezones.to_utc(~D[2027-11-07], ~T[01:30:00], "America/New_York") ==
               ~U[2027-11-07 05:30:00Z]
    end

    test "an unknown zone raises" do
      assert_raise ArgumentError, fn ->
        Timezones.to_utc(~D[2027-01-01], ~T[07:00:00], "Nowhere/Special")
      end
    end
  end

  test "today/2 is the local date" do
    # 23:30 UTC on the 1st is already the 2nd in Tokyo, still the 1st in New York.
    now = ~U[2027-01-01 23:30:00Z]
    assert Timezones.today("Asia/Tokyo", now) == ~D[2027-01-02]
    assert Timezones.today("America/New_York", now) == ~D[2027-01-01]
  end

  describe "the user's timezone" do
    test "a new user has none, and the browser's is adopted once" do
      user = user_fixture()
      assert user.timezone == nil

      user = Accounts.adopt_browser_timezone(user, "Europe/London")
      assert user.timezone == "Europe/London"
      assert Accounts.get_user!(user.id).timezone == "Europe/London"

      # A later browser in another zone doesn't move it.
      user = Accounts.adopt_browser_timezone(user, "Asia/Tokyo")
      assert Accounts.get_user!(user.id).timezone == "Europe/London"
    end

    test "a browser zone the database doesn't know is ignored" do
      user = Accounts.adopt_browser_timezone(user_fixture(), "Not/AZone")
      assert user.timezone == nil
      assert Accounts.get_user!(user.id).timezone == nil
      assert Accounts.adopt_browser_timezone(user, nil).timezone == nil
    end

    test "the profile changes it, and refuses an invalid zone" do
      user = user_fixture()
      assert {:ok, user} = Accounts.update_profile(user, %{"timezone" => "America/New_York"})
      assert user.timezone == "America/New_York"

      assert {:error, cs} = Accounts.update_profile(user, %{"timezone" => "Atlantis/Capital"})
      assert %{timezone: [msg]} = errors_on(cs)
      assert msg =~ "isn't a timezone"
      assert Accounts.get_user!(user.id).timezone == "America/New_York"
    end
  end
end
