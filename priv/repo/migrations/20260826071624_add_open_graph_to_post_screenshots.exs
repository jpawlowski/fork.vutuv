defmodule Vutuv.Repo.Migrations.AddOpenGraphToPostScreenshots do
  use Ecto.Migration

  # The preview a linked page publishes about itself (Open Graph): the row that
  # was only ever a screenshot now also carries the publisher's own headline,
  # teaser and site name, and `source` says which of the two it is.
  #
  # `text`, not varchar(255): the values come from a remote page, so nothing
  # here is ours to bound — the display caps live in `Vutuv.OpenGraph`
  # (title 300, description 1000, site_name 100), applied on ingest. A
  # varchar column would answer an over-long og:description with a 22001 in
  # the worker instead.
  #
  # Plain additions, so the currently deployed release keeps working unchanged
  # (it selects the columns it knows and writes no `source`, which reads back
  # as "screenshot").
  def change do
    alter table(:post_screenshots) do
      add(:title, :text)
      add(:description, :text)
      add(:site_name, :text)
      add(:source, :string, default: "screenshot", null: false)
    end
  end
end
