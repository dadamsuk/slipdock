defmodule Slipdock.QuickAddTest do
  use ExUnit.Case, async: true

  alias Slipdock.QuickAdd

  # A Saturday.
  @today ~D[2026-09-26]

  @board %{
    columns: [%{id: 1, name: "Backlog"}, %{id: 2, name: "To Do"}, %{id: 3, name: "In Progress"}],
    tags: [%{id: 10, name: "docs"}, %{id: 11, name: "Front-end"}]
  }
  @users [
    %Slipdock.Accounts.User{id: 5, name: "Dan Adams", email: "dan@example.com"},
    %Slipdock.Accounts.User{id: 6, name: nil, email: "sam@example.com"}
  ]

  defp parse(text), do: QuickAdd.parse(text, @board, today: @today, users: @users)

  test "a plain title has no commands" do
    parsed = parse("  Write the   launch post ")
    assert parsed.title == "Write the launch post"
    assert parsed.attrs == %{}
    refute QuickAdd.commands?(parsed)
  end

  test "after one semicolon the description, after two the comment, both taken as written" do
    parsed =
      parse("Write the launch post #high; check with @sam; due: tomorrow;; ask #docs first ")

    assert parsed.title == "Write the launch post"
    assert parsed.description == "check with @sam; due: tomorrow"
    assert parsed.comment == "ask #docs first"
    # Commands are only read in the title.
    assert parsed.attrs == %{"priority" => "high", "description" => parsed.description}
    assert parsed.tags == []
    assert {:description, "Description"} in parsed.chips
    assert {:comment, "Comment"} in parsed.chips
    assert QuickAdd.commands?(parsed)
  end

  test "one semicolon gives a description and no comment" do
    parsed = parse("Write it; the long version")
    assert parsed.description == "the long version"
    assert parsed.attrs == %{"description" => "the long version"}
    assert parsed.comment == nil
    refute {:comment, "Comment"} in parsed.chips
  end

  test "two semicolons straight after the title give a comment and no description" do
    parsed = parse("Write it;; ask Sam")
    assert parsed.title == "Write it"
    assert parsed.description == nil
    assert parsed.attrs == %{}
    assert parsed.comment == "ask Sam"
    refute {:description, "Description"} in parsed.chips
  end

  test "empty parts leave nothing" do
    for line <- ["Write it;   ", "Write it;;", "Write it; ;; ", "Write it"] do
      parsed = parse(line)
      assert parsed.title == "Write it"
      assert parsed.description == nil
      assert parsed.comment == nil
      refute QuickAdd.commands?(parsed)
    end
  end

  test "split_parts/1 splits title, description and comment" do
    assert QuickAdd.split_parts("A; b;; c") == {"A", "b", "c"}
    assert QuickAdd.split_parts("A;; c; d") == {"A", nil, "c; d"}
    assert QuickAdd.split_parts("A") == {"A", nil, nil}
  end

  test "a line with no title has none" do
    parsed = parse("; just a note;; and a comment")
    assert parsed.title == ""
    assert parsed.description == "just a note"
    assert parsed.comment == "and a comment"
  end

  test "due and start dates, priority, flag, list, tag and assignee all come out of the line" do
    parsed =
      parse("Write the launch post due: tomorrow start: today #high #todo #docs #blocked @dan")

    assert parsed.title == "Write the launch post"

    assert parsed.attrs == %{
             "due_date" => "2026-09-27",
             "start_date" => "2026-09-26",
             "priority" => "high",
             "flags" => ["blocked"],
             "assignee_id" => 5,
             "assignee_ids" => [5]
           }

    assert parsed.column.name == "To Do"
    assert Enum.map(parsed.tags, & &1.name) == ["docs"]
    assert parsed.assignee.id == 5
    assert parsed.unknown == []

    assert Enum.map(parsed.chips, &elem(&1, 1)) == [
             "Due Sun 27 Sep",
             "Start Sat 26 Sep",
             "Dan Adams",
             "high",
             "To Do",
             "docs",
             "blocked"
           ]
  end

  test "list and tag names match loosely, unknown words stay in the title" do
    parsed = parse("Fix nav #in-progress #FrontEnd #nope @sam")
    assert parsed.title == "Fix nav #nope"
    assert parsed.column.name == "In Progress"
    assert Enum.map(parsed.tags, & &1.name) == ["Front-end"]
    assert parsed.assignee.email == "sam@example.com"
    assert parsed.unknown == ["#nope"]
  end

  test "the word due without a date is just a word" do
    parsed = parse("Pay what is due")
    assert parsed.title == "Pay what is due"
    assert parsed.attrs == %{}
  end

  test "date phrases" do
    for {phrase, expected} <- [
          {"today", ~D[2026-09-26]},
          {"tomorrow", ~D[2026-09-27]},
          {"tom", ~D[2026-09-27]},
          {"mon", ~D[2026-09-28]},
          {"monday", ~D[2026-09-28]},
          {"sat", ~D[2026-09-26]},
          {"next sat", ~D[2026-10-03]},
          {"next week", ~D[2026-09-28]},
          {"next month", ~D[2026-10-01]},
          {"in 3 days", ~D[2026-09-29]},
          {"in 2 weeks", ~D[2026-10-10]},
          {"in 1 month", ~D[2026-10-26]},
          {"+3", ~D[2026-09-29]},
          {"+2w", ~D[2026-10-10]},
          {"eow", ~D[2026-09-27]},
          {"eom", ~D[2026-09-30]},
          {"2026-10-01", ~D[2026-10-01]},
          {"1 oct", ~D[2026-10-01]},
          {"1st October", ~D[2026-10-01]},
          {"oct 1", ~D[2026-10-01]},
          {"1/10", ~D[2026-10-01]},
          {"1/3", ~D[2027-03-01]},
          {"1/3/26", ~D[2026-03-01]},
          {"5 jan 2027", ~D[2027-01-05]}
        ] do
      assert {:ok, ^expected} = QuickAdd.parse_date(phrase, @today), phrase
    end

    assert {:ok, nil} = QuickAdd.parse_date("none", @today)
    assert :error = QuickAdd.parse_date("someday", @today)
    assert :error = QuickAdd.parse_date("31/2", @today)
  end

  test "dates can be written without the colon or with 'by'" do
    assert parse("Ship it by friday").attrs == %{"due_date" => "2026-10-02"}

    assert parse("Ship it due:2026-10-05 start next mon").attrs == %{
             "due_date" => "2026-10-05",
             "start_date" => "2026-09-28"
           }
  end
end
