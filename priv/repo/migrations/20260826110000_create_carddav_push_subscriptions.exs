defmodule Vutuv.Repo.Migrations.CreateCarddavPushSubscriptions do
  use Ecto.Migration

  @moduledoc """
  WebDAV-Push subscriptions for the CardDAV address book (issue #1705): one row
  per device that asked to be told when its address book changes, instead of
  asking us every quarter of an hour.

  The transport is Web Push (RFC 8030/8291/8292) — the same machinery
  `Vutuv.MastodonApi.WebPush` already speaks, signed with this installation's
  own VAPID key. Nobody issues that key and no third party is involved.

  `push_resource` is the device's push endpoint, **`:text` and not
  varchar(255)**: it is a URL somebody else's push service hands out and its
  length is not ours to bound (the same lesson `fediverse_post_deliveries`
  learned). The two key columns are base64url of fixed-size binaries, so they
  are bounded and validated in the changeset.

  `last_revision` is the `users.carddav_revision` this device was last told
  about; a push goes out only when the book moved past it, which makes the
  sweep idempotent. `checked_at` is the sweeper's own clock and is stamped on
  **every** outcome, including the ones where nothing was sent — an item that
  cannot be worked on must still leave the front of the queue (see CLAUDE.md).

  N-1 safe: a new table.
  """

  def change do
    create table(:carddav_push_subscriptions) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:push_resource, :text, null: false)
      add(:p256dh, :string, null: false)
      add(:auth_secret, :string, null: false)
      add(:expires_at, :utc_datetime, null: false)
      add(:last_revision, :bigint, null: false, default: 0)
      add(:checked_at, :naive_datetime)

      timestamps()
    end

    create(index(:carddav_push_subscriptions, [:user_id]))
    # The sweeper's batch: least recently checked first, nulls (never checked)
    # ahead of everything.
    create(index(:carddav_push_subscriptions, [:checked_at]))
  end
end
