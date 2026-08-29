defmodule Vutuv.Repo.Migrations.AddQuotesToFediversePosts do
  use Ecto.Migration

  # What a post from another network says it is quoting (issue #1609).
  #
  # `quote_uri` is the object the author quoted, read from whichever of the
  # three alias properties their server writes (`quote`, `quoteUri`,
  # `_misskey_quote`); `quote_authorization_uri` is the FEP-044f stamp that
  # proves the quoted author consented. Both are **text**: they are URIs a
  # stranger's server minted, no changeset of ours bounds what they may write,
  # and a varchar(255) would turn a long id into a 22001 on the delivery path —
  # the `inbox_uri` lesson from issue #1102. The changeset caps them in bytes
  # like `object_uri`, but the column is not what does it.
  #
  # The two resolved references are the quoted thing itself: a cached copy of
  # somebody else's post, or a vutuv post when the quote points back here.
  # Nilify rather than cascade — a quote outlives what it quotes and degrades
  # to a link, exactly as it does when the stamp is withdrawn. The
  # `quoted_post_id` reference is also the **holder** that keeps a quoted
  # remote copy out of `purge_unfollowed_remote_posts/0`, the way a reshare, a
  # boost and a lookup hold one.
  #
  # `quote_verified` is what decides between a card and a link: true only for a
  # self-quote or a stamp we checked against the quoted object's own host.
  # Default false, so an unresolved row renders as the link it already was.
  #
  # Plain additions, so this is N-1 compatible: the release currently serving
  # traffic neither reads nor writes any of them.
  # The two indexes are built CONCURRENTLY, so the migration takes no
  # transaction and no migrator lock. `fediverse_posts` is the table the inbox
  # writes to on every delivery, and a migration runs during the blue/green
  # window while the **previous** release is still serving — an ordinary
  # `CREATE INDEX` would hold a write lock on it for the duration. The column
  # additions themselves are metadata-only and safe beside it.
  #
  # **Every step is therefore idempotent**, which is the price of giving up the
  # transaction: a concurrent build that loses a lock race leaves the columns
  # added and the version unrecorded, and the deploy's retry would otherwise die
  # on "column already exists" and block every migration behind it.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # `up`/`down` rather than `change`, because `add_if_not_exists` carries no
  # reverse. Nothing is lost: the down side drops exactly what the up side adds.
  def up do
    alter table(:fediverse_posts) do
      add_if_not_exists(:quote_uri, :text)
      add_if_not_exists(:quote_authorization_uri, :text)

      add_if_not_exists(
        :quoted_post_id,
        references(:fediverse_posts, on_delete: :nilify_all, type: :binary_id)
      )

      add_if_not_exists(
        :quoted_local_post_id,
        references(:posts, on_delete: :nilify_all, type: :binary_id)
      )

      add_if_not_exists(:quote_verified, :boolean, null: false, default: false)
    end

    # The holder question — "does any post quote this one" — is asked once per
    # purge run per candidate row, so the reference needs its own index; the
    # local one covers the same question for a vutuv post.
    create_if_not_exists(index(:fediverse_posts, [:quoted_post_id], concurrently: true))
    create_if_not_exists(index(:fediverse_posts, [:quoted_local_post_id], concurrently: true))
  end

  def down do
    drop_if_exists(index(:fediverse_posts, [:quoted_post_id], concurrently: true))
    drop_if_exists(index(:fediverse_posts, [:quoted_local_post_id], concurrently: true))

    alter table(:fediverse_posts) do
      remove_if_exists(:quote_uri, :text)
      remove_if_exists(:quote_authorization_uri, :text)
      remove_if_exists(:quoted_post_id, :binary_id)
      remove_if_exists(:quoted_local_post_id, :binary_id)
      remove_if_exists(:quote_verified, :boolean)
    end
  end
end
