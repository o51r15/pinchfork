defmodule Pinchflat.Repo.Migrations.WidenSourceTextColumns do
  use Ecto.Migration

  def up do
    alter table(:sources) do
      modify :description, :text
      modify :original_url, :text
      modify :output_path_template_override, :text
      modify :title_filter_regex, :text
    end
  end

  def down do
    alter table(:sources) do
      modify :description, :string
      modify :original_url, :string
      modify :output_path_template_override, :string
      modify :title_filter_regex, :string
    end
  end
end
