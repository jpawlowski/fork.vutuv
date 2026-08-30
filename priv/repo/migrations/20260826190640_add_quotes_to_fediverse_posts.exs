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
  # `quote_checked_at` is the resume clock. Resolving a quote is fire-and-forget
  # work on `Vutuv.TaskSupervisor`, so a blue/green deploy stops it mid-flight
  # and nothing anywhere says so — the row would keep a `quote_uri` nobody ever
  # went back to. Every finished resolution stamps this column, *including* the
  # ones that resolved to nothing, so a null clock means one thing only: the
  # attempt never got to the end. `Vutuv.Fediverse.QuoteResolver` picks exactly
  # those up. The stamp is what stops it being a treadmill (issue #1316): each
  # row is retried once and then leaves the queue whatever the outcome.
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
  # on "column already exists" and block every migration behind it. The two
  # foreign keys need their own guard for that (`add_foreign_key/3`); the
  # columns' own `if_not_exists` does not cover them.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # `up`/`down` rather than `change`, because `add_if_not_exists` carries no
  # reverse. Nothing is lost: the down side drops exactly what the up side adds.
  def up do
    alter table(:fediverse_posts) do
      add_if_not_exists(:quote_uri, :text)
      add_if_not_exists(:quote_authorization_uri, :text)
      # Bare `:binary_id` here and the foreign key below, because
      # `add_if_not_exists` guards only the column: handed a `references/2` it
      # still emits an unguarded `ALTER TABLE … ADD CONSTRAINT` beside it, and
      # Postgres has no `ADD CONSTRAINT IF NOT EXISTS`. On the retry this
      # migration is written for, that constraint is the step that dies (42710,
      # "constraint already exists") and takes every migration behind it down
      # with it — the failure the columns were made idempotent to avoid.
      add_if_not_exists(:quoted_post_id, :binary_id)
      add_if_not_exists(:quoted_local_post_id, :binary_id)
      add_if_not_exists(:quote_verified, :boolean, null: false, default: false)
      add_if_not_exists(:quote_checked_at, :utc_datetime)
    end

    add_foreign_key("quoted_post_id", "fediverse_posts")
    add_foreign_key("quoted_local_post_id", "posts")

    # The holder question — "does any post quote this one" — is asked once per
    # purge run per candidate row, so the reference needs its own index; the
    # local one covers the same question for a vutuv post.
    create_if_not_exists(index(:fediverse_posts, [:quoted_post_id], concurrently: true))
    create_if_not_exists(index(:fediverse_posts, [:quoted_local_post_id], concurrently: true))

    # The resume queue, asked for every two minutes and empty almost every time.
    # Partial and on `id`, exactly like `fediverse_posts_language_detection_index`
    # beside it: the rows it looks for are the rare ones — a quote nobody
    # finished resolving — and `id` is both the sort key (UUID v7, so id order is
    # creation order) and all the index has to carry. Without the predicate this
    # is a sequential scan over every cached post on the installation, every two
    # minutes, to answer "none".
    create_if_not_exists(
      index(:fediverse_posts, [:id],
        name: :fediverse_posts_unresolved_quotes_index,
        where:
          "quote_uri IS NOT NULL AND quote_checked_at IS NULL AND quoted_post_id IS NULL AND quoted_local_post_id IS NULL",
        concurrently: true
      )
    )
  end

  # The guarded half of a `references/2`, and the only spelling Postgres leaves:
  # it has no `ADD CONSTRAINT IF NOT EXISTS`, so the existence check is the `DO`
  # block. The name is the one Ecto would have given it, so a database already
  # carrying the constraint from a half-finished run is recognised. Both new
  # columns are NULL on every existing row, so validating the constraint reads a
  # table it can only agree with.
  defp add_foreign_key(column, referenced) do
    name = "fediverse_posts_#{column}_fkey"

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{name}' AND conrelid = 'fediverse_posts'::regclass
      ) THEN
        ALTER TABLE fediverse_posts
          ADD CONSTRAINT #{name} FOREIGN KEY (#{column})
          REFERENCES #{referenced}(id) ON DELETE SET NULL;
      END IF;
    END $$;
    """)
  end

  def down do
    drop_if_exists(index(:fediverse_posts, [:quoted_post_id], concurrently: true))
    drop_if_exists(index(:fediverse_posts, [:quoted_local_post_id], concurrently: true))

    drop_if_exists(
      index(:fediverse_posts, [:id],
        name: :fediverse_posts_unresolved_quotes_index,
        concurrently: true
      )
    )

    alter table(:fediverse_posts) do
      remove_if_exists(:quote_uri, :text)
      remove_if_exists(:quote_authorization_uri, :text)
      remove_if_exists(:quoted_post_id, :binary_id)
      remove_if_exists(:quoted_local_post_id, :binary_id)
      remove_if_exists(:quote_verified, :boolean)
      remove_if_exists(:quote_checked_at, :utc_datetime)
    end
  end
end
