defmodule Slipdock.PolicyActions do
  @moduledoc """
  The rows of `Slipdock.Policy`'s table each Policy card tests, by card, so
  one test can hold the table to the tests: a row nobody tests fails it
  (`test/slipdock/policy_boards_test.exs`).
  """

  @doc "Policy 1 (#3168): tags."
  def tags, do: ~w(create_tag update_tag delete_tag toggle_card_tag)a

  @doc "Policy 3 (#3170): boards, lists, views, sprints and grants, with the level each needs."
  def boards do
    [
      create_board: :owner,
      update_board: :write,
      delete_board: :owner,
      archive_board: :owner,
      edit_sub_board: :write,
      edit_list: :write,
      place_in_list: :write,
      edit_view: :write,
      publish_view: :owner,
      edit_sprint: :write,
      add_to_sprint: :write,
      arrange_own: :owner,
      own_template: :owner,
      share_board: :owner,
      share_view: :owner,
      share_card: :write,
      share_page: :write,
      share_folder: :write,
      share_tool: :owner
    ]
  end
end
