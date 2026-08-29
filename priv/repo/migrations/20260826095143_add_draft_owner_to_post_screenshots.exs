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
  # or `remote_post_id`). The CHECK is validated against the existing rows, so
  # it costs one short seq scan of a small table — no data is rewritten.
  #
  # `up`/`down` rather than `change`, because `drop(constraint/1)` has no
  # reverse: in a `change/0` a rollback raises instead of rolling back. Same
  # shape as `20260810165508_add_organization_authorship_to_posts.exs`, which
  # widened the posts table's own exactly-one-author check.
  def up do
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

  def down do
    drop(constraint(:post_screenshots, :post_screenshots_exactly_one_owner))

    # A draft-owned row has no owner left once the column goes, so it would
    # fail the two-way check the previous release used.
    execute("DELETE FROM post_screenshots WHERE post_draft_id IS NOT NULL")

    drop(unique_index(:post_screenshots, [:post_draft_id]))

    alter table(:post_screenshots) do
      remove(:post_draft_id)
    end

    create(
      constraint(:post_screenshots, :post_screenshots_exactly_one_owner,
        check: "(post_id IS NULL) <> (remote_post_id IS NULL)"
      )
    )
  end
end
