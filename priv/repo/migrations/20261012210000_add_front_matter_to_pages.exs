defmodule Slipdock.Repo.Migrations.AddFrontMatterToPages do
  use Ecto.Migration

  # A page imported (or, later, synced) from a Markdown file keeps that file's
  # front matter exactly as written — delimiters, key order, quoting, comments
  # — so the file it came from can be written back byte for byte (see
  # `Slipdock.Wiki.FrontMatter`, W-103 R3).
  def change do
    alter table(:pages) do
      add :front_matter, :text
    end
  end
end
