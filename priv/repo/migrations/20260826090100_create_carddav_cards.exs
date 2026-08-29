defmodule Vutuv.Repo.Migrations.CreateCarddavCards do
  use Ecto.Migration

  @moduledoc """
  The CardDAV address book (issue #1705): the member's sharing level, the
  per-member revision counter its sync token is made of, and one row per card
  a member currently publishes.

  **Why a table at all.** A phone asks "what changed since token N?"
  (`sync-collection`, RFC 6578) and expects three answers: added, changed,
  **gone**. The last one cannot be derived from the live data — once a follow
  is dropped there is nothing left to report — so the set a member last handed
  out is remembered here, and a card that stops qualifying becomes a tombstone
  (`deleted: true`) with a fresh revision instead of vanishing. That tombstone
  is what turns "I unfollowed them" into "their card left my phone".

  `revision` is `users.carddav_revision` at the moment the row last changed;
  that counter is bumped atomically (`UPDATE … SET carddav_revision =
  carddav_revision + 1 RETURNING`), so it is monotonic per member without a
  lock and two concurrent syncs cannot mint the same number.

  `etag` is a hash of the rendered card. It is what tells a poll that nothing
  changed, so it must cover everything the card shows — including the photo,
  which rides in as `users.avatar_fingerprint` rather than as megabytes of
  base64.

  Tombstones are kept, not swept: they are three columns per contact a member
  ever dropped, and a phone that has been in a drawer for a year still deserves
  a correct answer.

  N-1 safe: a new table plus two nullable-or-defaulted columns.
  """

  def change do
    alter table(:users) do
      # Which contacts this member publishes over CardDAV. "off" for everybody
      # until they choose otherwise — the address book is other people's data.
      add(:carddav_sharing, :string, null: false, default: "off")
      # The member's own sync-token counter. Never decreases.
      add(:carddav_revision, :bigint, null: false, default: 0)
    end

    create table(:carddav_cards) do
      # The subscriber — whose address book this row belongs to.
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # The member the card is about.
      add(:contact_id, references(:users, on_delete: :delete_all), null: false)
      add(:etag, :string, null: false)
      add(:revision, :bigint, null: false)
      add(:deleted, :boolean, null: false, default: false)

      timestamps()
    end

    create(unique_index(:carddav_cards, [:user_id, :contact_id]))
    # The sync report's only query: "my rows past revision N", newest last.
    create(index(:carddav_cards, [:user_id, :revision]))
  end
end
