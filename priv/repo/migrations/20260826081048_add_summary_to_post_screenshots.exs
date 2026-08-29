defmodule Vutuv.Repo.Migrations.AddSummaryToPostScreenshots do
  use Ecto.Migration

  # The sentence a reader gets when they hover a link preview: what the linked
  # page is about, written by a local model off the whole page (issue #1709,
  # `Vutuv.LinkSummary`).
  #
  # `text`, not varchar(255): the value is generated, not typed into a form, so
  # a column limit would be enforced by Postgres raising 22001 in the capture
  # worker rather than by a changeset error anybody sees. The length that
  # matters is the 200-character cap `Vutuv.LinkSummary.clamp/1` applies before
  # the value is ever stored.
  #
  # A plain addition: the currently deployed release selects the columns it
  # knows and never writes this one, which reads back as "no summary yet" — the
  # same state every row is in before its capture runs.
  def change do
    alter table(:post_screenshots) do
      add(:summary, :text)
    end
  end
end
