defmodule Slipdock.Tools.File do
  @moduledoc """
  One file of a published Tool version, at its path in the package
  (`tool.json`, `skills/job-scan/SKILL.md`, `files/cv.docx`), with its bytes.
  """
  use Ecto.Schema

  schema "tool_files" do
    field :path, :string
    field :content, :binary
    field :size, :integer
    field :sha256, :string
    belongs_to :version, Slipdock.Tools.Version
  end
end
