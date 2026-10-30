defmodule Slipdock.Repo.Migrations.CreateDocumentTexts do
  use Ecto.Migration

  # The words read out of an uploaded PDF or image (#1527). Its own table
  # rather than columns on `attachments` and `wiki_files`: it is also the
  # queue, it can hold a megabyte of text that nothing listing files wants,
  # and both kinds of file share it.
  def up do
    create table(:document_texts) do
      add :attachment_id, references(:attachments, on_delete: :delete_all)
      add :wiki_file_id, references(:wiki_files, on_delete: :delete_all)
      add :status, :string, null: false, default: "queued"
      add :text, :text
      add :error, :text
      add :pages, :integer
      add :ocr_pages, :integer
      add :truncated, :boolean, null: false, default: false
      add :attempts, :integer, null: false, default: 0
      add :started_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_texts, [:attachment_id])
    create unique_index(:document_texts, [:wiki_file_id])
    create index(:document_texts, [:status])

    create constraint(:document_texts, :document_texts_one_source,
             check:
               "(attachment_id IS NOT NULL AND wiki_file_id IS NULL) OR " <>
                 "(attachment_id IS NULL AND wiki_file_id IS NOT NULL)"
           )

    # A wiki file is a third thing a chunk can belong to.
    alter table(:search_embeddings) do
      add :file_id, references(:wiki_files, on_delete: :delete_all)
    end

    create index(:search_embeddings, [:file_id])

    drop constraint(:search_embeddings, :search_embeddings_card_xor_page)

    create constraint(:search_embeddings, :search_embeddings_one_owner,
             check:
               "(card_id IS NOT NULL AND page_id IS NULL AND file_id IS NULL) OR " <>
                 "(card_id IS NULL AND page_id IS NOT NULL AND file_id IS NULL) OR " <>
                 "(card_id IS NULL AND page_id IS NULL AND file_id IS NOT NULL)"
           )
  end

  def down do
    drop constraint(:search_embeddings, :search_embeddings_one_owner)
    execute "DELETE FROM search_embeddings WHERE file_id IS NOT NULL"

    create constraint(:search_embeddings, :search_embeddings_card_xor_page,
             check:
               "(card_id IS NOT NULL AND page_id IS NULL) OR " <>
                 "(card_id IS NULL AND page_id IS NOT NULL)"
           )

    drop index(:search_embeddings, [:file_id])

    alter table(:search_embeddings) do
      remove :file_id
    end

    drop table(:document_texts)
  end
end
