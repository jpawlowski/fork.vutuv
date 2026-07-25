defmodule Vutuv.Repo.Migrations.DropAudienceGroups do
  use Ecto.Migration

  @moduledoc """
  Expand/contract step 2 of 2 for the audience-Groups removal (commit 02589063,
  2026-06-13). That deploy dropped every line of the feature's code — the
  controllers, schemas, composer sheet and the group branch of the post
  visibility query — but deliberately kept its tables and the
  `post_denials.group_id` column so the release still serving traffic during
  the blue/green window kept working (the N-1 rule). That window closed with
  the very next deploy; this finally removes them.

  Dropped here:
  - `post_denials.group_id` and its RESTRICT foreign key to `groups`. A denial
    has targeted a single user or a wildcard since that deploy, so no live code
    could have minted a group denial in the meantime.
  - the `memberships` table (who was in which group),
  - the `groups` table itself.

  The row counts are printed before the drop, so the deploy log records what
  was there. The feature had no reachable management UI, which is why it was
  removed: nothing could build a group, and any surviving row is a relic of the
  pre-redesign site.

  N-1 safe: the currently deployed release already reads and writes none of
  this. The one thing that still referenced the column was the defensive
  posts-first ordering in `Vutuv.Accounts.delete_user/1`, dropped in the same
  release — every remaining foreign key into `posts` cascades or nilifies, so
  the plain `Repo.delete!(user)` cascade is enough on its own.
  """

  @counted [
    {"groups", "SELECT count(*) FROM groups"},
    {"memberships", "SELECT count(*) FROM memberships"},
    {"post_denials naming a group", "SELECT count(*) FROM post_denials WHERE group_id IS NOT NULL"}
  ]

  def up do
    for {label, sql} <- @counted do
      %{rows: [[count]]} = repo().query!(sql, [])
      IO.puts("drop_audience_groups: #{label}: #{count}")
    end

    alter table(:post_denials) do
      remove(:group_id)
    end

    drop(table(:memberships))
    drop(table(:groups))
  end

  def down do
    # Best-effort: the schema comes back, the rows do not. They described a
    # feature no member could reach and cannot be reconstructed here.
    create table(:groups) do
      add(:name, :string)
      add(:user_id, references(:users, on_delete: :delete_all))

      timestamps()
    end

    create(index(:groups, [:user_id]))

    create table(:memberships) do
      add(:follow_id, references(:follows, on_delete: :delete_all))
      add(:group_id, references(:groups, on_delete: :delete_all))

      timestamps()
    end

    create(index(:memberships, [:follow_id]))
    create(index(:memberships, [:group_id]))

    alter table(:post_denials) do
      add(:group_id, references(:groups, on_delete: :restrict))
    end
  end
end
