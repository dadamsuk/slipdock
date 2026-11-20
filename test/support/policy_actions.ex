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
      let_editors_share: :owner,
      share_tool: :owner,
      share_pool: :owner
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

  @doc "Policy 5 (#3172): a person's own rows and the server's accounts, with the level each needs."
  def own do
    [
      own_settings: :owner,
      own_view: :owner,
      own_work: :owner,
      own_group: :owner,
      own_sign_in: :owner,
      own_transfer_link: :read,
      administer: :owner
    ]
  end

  @doc "Policy 7 (#3174): owner and admin writes, with the level each needs."
  def owner_admin do
    [
      edit_rule: :owner,
      own_alert: :owner,
      triage_finding: :write,
      decide_suggestion: :write,
      decide_in_person: :write,
      propose_edit: :write,
      run_board_check: :write,
      enable_skill: :write,
      own_source: :owner,
      own_tool: :owner,
      sign_card: :owner
    ]
  end
end
