defmodule Vutuv.Repo.Migrations.CreateFediverseNotes do
  use Ecto.Migration

  # Replies written on other networks under a member's post (issues #1069 and
  # #1071). The first time vutuv stores a stranger's *words*, which is why this
  # table carries a clock and the reactions table (#1068) does not: a counter row
  # says nothing about a person, a sentence with their name on it does.
  #
  # What is deliberately absent: any copy of their picture. The card renders
  # initials and links to the origin, so we never host a third party's image.
  #
  # The retention triple is the whole legal footing, since consent from someone
  # on another server is not obtainable:
  #
  #   received_at — when it arrived,
  #   checked_at  — when we last confirmed it is still published at its origin,
  #   expires_at  — the hard ceiling, six months out, which a confirmed-live
  #                 note pushes forward and nothing else does.
  #
  # New tables + a new column with a default -> N-1 safe for the blue/green
  # window.
  def change do
    create table(:fediverse_notes) do
      add(:post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false)

      # The note's own AP id and the actor who wrote it. `text`, because remote
      # URIs are unbounded in theory; the schema caps the length in BYTES before
      # anything is written, because object_uri carries a btree unique index
      # whose key has a hard size limit.
      add(:object_uri, :text, null: false)
      add(:actor_uri, :text, null: false)
      # Where a human reads the original. Mastodon serves this separately from
      # the id; we fall back to the id when it is absent.
      add(:origin_url, :text)
      # What the note answered, as delivered. Unused while only direct answers
      # to a vutuv post are stored, kept so remote-to-remote nesting is later a
      # change and not a migration.
      add(:in_reply_to_uri, :text)

      # Cosmetic, remote-supplied and hostile: capped at the usual varchar(255).
      add(:handle, :string)
      add(:display_name, :string)

      # Plain text, never HTML: nothing a stranger wrote is ever rendered raw.
      # `text` with a generous cap in the schema, per the varchar rule.
      add(:content_text, :text, null: false)
      # The note's content warning, if it carried one. Kept as its own column
      # rather than folded into the text, because a warning exists precisely so
      # the reader chooses whether to read what is behind it: the card renders
      # it as the closed lid and reveals the text on a click. Silently showing
      # a warned reply unwrapped would defeat the one thing its author asked
      # for.
      add(:summary, :text)

      # public | followers | direct | unknown (issue #1071). Only "public" is
      # public; every other value renders to the addressed member alone. The
      # distinction is kept rather than collapsed to a boolean so the member can
      # be told honestly what kind of message reached them.
      add(:audience, :string, null: false)

      add(:received_at, :utc_datetime, null: false)
      add(:checked_at, :utc_datetime)
      add(:expires_at, :utc_datetime, null: false)
    end

    # One row per remote note: a redelivery is an upsert, and an upstream
    # Update/Delete finds its row here.
    create(unique_index(:fediverse_notes, [:object_uri]))
    # The thread renderer's read: every note under one post, oldest first.
    create(index(:fediverse_notes, [:post_id, :received_at]))
    # The retention sweep's read.
    create(index(:fediverse_notes, [:expires_at]))
    # The per-actor takedown and the instance purge read this one.
    create(index(:fediverse_notes, [:actor_uri]))

    # The operator's window on the takedown path (issue #1069): what members are
    # removing, and from which servers, so a block decision has evidence behind
    # it.
    #
    # It keeps NO content and NO URIs, following the precedent
    # Vutuv.Fediverse.FollowerPrune set in #1072: retaining a stranger's words or
    # their online identifier after deleting the note would undo the deletion we
    # just promised. `actor_digest` is a keyed HMAC of the actor URI (peppered
    # from secret_key_base), which is enough to tell one troll from a whole
    # server without holding the identifier itself.
    #
    # Only member-initiated actions land here. Automatic deletions (expiry, an
    # upstream Delete, a server block) would flood the table and are reported in
    # aggregate to the log instead.
    create table(:fediverse_note_events) do
      add(:action, :string, null: false)
      add(:host, :string, null: false)
      add(:actor_digest, :string, null: false)
      add(:audience, :string, null: false)
      # Whose post the note sat under, and who acted. Plain values, not
      # associations: an audit row must stay readable after the rows it
      # references are gone.
      add(:user_id, :binary_id)
      add(:actor_id, :binary_id)

      timestamps(updated_at: false)
    end

    create(index(:fediverse_note_events, [:host]))
    create(index(:fediverse_note_events, [:inserted_at]))

    alter table(:users) do
      # The second, explicit opt-in (issue #1069): counts are one thing, a
      # stranger's words under your post are another. Off by default, unlike the
      # reaction counts, and switching it off deletes what was stored.
      add(:fediverse_replies?, :boolean, null: false, default: false)
    end
  end
end
