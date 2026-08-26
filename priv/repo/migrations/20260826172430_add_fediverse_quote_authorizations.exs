defmodule Vutuv.Repo.Migrations.AddFediverseQuoteAuthorizations do
  use Ecto.Migration

  # The consent half of FEP-044f quote posts (issue #1608): who was allowed to
  # quote which of our posts, and where to send the withdrawal.
  #
  # Additions only — a new table and two new booleans with defaults — so the
  # currently deployed release keeps working through the migration window.
  def change do
    create table(:fediverse_quote_authorizations) do
      # Deliberately plain ids, NOT references: the withdrawal runs *after* the
      # post row is gone (`Vutuv.Posts.delete_post/1` federates its Delete once
      # the transaction has committed), so a cascade would erase these rows
      # moments before they are needed. Cleared explicitly instead — by
      # `Vutuv.Fediverse.revoke_quote_authorizations/1`, by account deletion and
      # by an instance block. Exactly the reasoning behind
      # `fediverse_post_deliveries`, and for exactly the same failure.
      add(:post_id, :binary_id, null: false)
      # The author, in the usual nullable pair: a member or a page, never both.
      # An invariant of the context function that writes these, not of the
      # schema, because the row has to outlive whichever one it names.
      add(:user_id, :binary_id)
      add(:organization_id, :binary_id)

      # The remote post doing the quoting, its author, and where a
      # `Delete(QuoteAuthorization)` reaches that author. All three are remote
      # URIs and none of them is ours to bound, so `:text` — the type
      # `fediverse_followers.inbox_uri` already carries. A varchar(255) here
      # would raise Postgres 22001 out of the inbox for a perfectly ordinary
      # long status id, and no changeset would have caught it because nothing
      # user-facing writes this column.
      add(:interacting_object_uri, :text, null: false)
      add(:actor_uri, :text, null: false)
      add(:inbox_uri, :text)

      # The `QuoteRequest` this answers, so a redelivery of the same request
      # finds its row instead of minting a second stamp.
      add(:request_activity_id, :text)

      # The published Note id at the time consent was given. Same reason
      # `fediverse_post_deliveries` records it: a Note id carries the username,
      # and after a rename an id rebuilt from the current one names nothing the
      # other server stored.
      add(:note_uri, :text, null: false)

      add(:accepted_at, :utc_datetime, null: false)

      timestamps(updated_at: false)
    end

    # One stamp per (post, quoting object): a redelivered QuoteRequest upserts
    # rather than handing the same quote a second authorization.
    #
    # Both columns are hashed rather than indexed directly: `interacting_object_uri`
    # is unbounded `:text`, and a btree entry has a hard ~2704-byte ceiling, so a
    # hostile multi-kilobyte id would fail the INSERT (a 500 out of the inbox)
    # instead of the changeset. The changeset caps it at 2048 bytes as well; this
    # is the belt to that pair of braces.
    create(
      unique_index(:fediverse_quote_authorizations, [:post_id, :interacting_object_uri],
        name: :fediverse_quote_authorizations_post_object_index
      )
    )

    # The withdrawal path reads by post; the instance block reads by author host
    # through `actor_uri`.
    create(index(:fediverse_quote_authorizations, [:user_id]))
    create(index(:fediverse_quote_authorizations, [:organization_id]))

    # May other accounts quote my posts? Read by the `interactionPolicy` the
    # Note advertises and by the inbox gate that answers a QuoteRequest.
    #
    # Default **true**, unlike `fediverse_replies?` beside it: a quote
    # redistributes a post that is already public to anyone, which is what a
    # reshare has always done here, whereas holding text written by somebody who
    # never signed up is a different kind of ask. Switching it off means the
    # policy says `nobody` and every QuoteRequest is rejected.
    alter table(:users) do
      add(:fediverse_quotes?, :boolean, null: false, default: true)
    end

    alter table(:organizations) do
      add(:fediverse_quotes?, :boolean, null: false, default: true)
    end
  end
end
