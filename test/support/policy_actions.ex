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

  @doc "Policy 4 (#3171): the wiki, vaults and recordings, with the level each needs."
  def wiki do
    [
      create_wiki_item: :write,
      edit_page: :write,
      archive_page: :write,
      delete_page: :owner,
      purge_revisions: :owner,
      publish_page: :write,
      place_page: :write,
      pin_page: :write,
      pin_to_card: :write,
      link_page: :read,
      write_up_card: :write,
      arrange_wiki: :write,
      edit_folder: :write,
      delete_folder: :write,
      purge_folder: :owner,
      file_also: :write,
      edit_file: :write,
      archive_file: :write,
      delete_file: :owner,
      move_wiki_out: :write,
      move_wiki_in: :write,
      adopt_knowledge_base: :owner,
      install_handbook: :write,
      reread_file: :write,
      transcribe_file: :write,
      own_draft: :owner,
      own_tree_state: :owner,
      own_vault: :owner,
      own_google: :owner
    ]
  end
end
