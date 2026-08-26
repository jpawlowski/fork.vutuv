defmodule Vutuv.Repo.Migrations.AddDraftOwnerToPostScreenshots do
  use Ecto.Migration

  # A composer draft (`post_drafts`) can own a link-preview job too, so the
  # author sees the card before publishing (issue #1714). A third mutually
  # exclusive owner column rather than a second table: the fetch, the storage,
  # the AI scan, the retries and the admin views are all the same work, and on
  # publish the row's owner simply flips from the draft to the post — the row
  # keeps its id, so its stored files never move and the scan never runs twice.
  #
  # N-1 compatible: the column is additive, and the widened check still accepts
  # every row the currently deployed release writes (it only ever sets `post_id`
  # or `remote_post_id`). Dropping and recreating a CHECK is a metadata change
  # on this table's size; the old release keeps inserting rows that satisfy it.
  def change do
    alter table(:post_screenshots) do
      add(:post_draft_id, references(:post_drafts, on_delete: :delete_all, type: :binary_id))
    end

    # One preview per draft, like the one-per-post and one-per-cached-post
    # indexes beside it.
    create(unique_index(:post_screenshots, [:post_draft_id]))

    drop(constraint(:post_screenshots, :post_screenshots_exactly_one_owner))

    # Exactly one of the three. Written as a count rather than the two-way `<>`
    # the pair used, because that spelling does not extend past two columns.
    create(
      constraint(:post_screenshots, :post_screenshots_exactly_one_owner,
        check: """
        (CASE WHEN post_id IS NULL THEN 0 ELSE 1 END)
          + (CASE WHEN remote_post_id IS NULL THEN 0 ELSE 1 END)
          + (CASE WHEN post_draft_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )
  end
end
