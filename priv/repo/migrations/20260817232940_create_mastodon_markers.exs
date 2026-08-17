defmodule Vutuv.Repo.Migrations.CreateMastodonMarkers do
  use Ecto.Migration

  @moduledoc """
  Where a client left off reading (Mastodon's `/api/v1/markers`).

  `GET` answered `{}` and there was no `POST` at all, so a client's reading
  position was never stored and never restored: relaunching the app dropped it
  back to whatever it could fetch, which is what a member sees as a timeline
  that "lost" everything it had.

  One row per identity **and** timeline. The identity is a member or a page
  acting through them, so `organization_id` is nullable — which the uniqueness
  has to survive: Postgres treats NULLs as distinct, so a single unique index
  over the three columns would let a member accumulate a new row per write.
  Two partial indexes instead, one for each side of that nil.

  `last_read_id` is a plain string, not a reference: a Mastodon id here can be a
  vutuv uuid **or** a prefixed derived id (`remote-<uuid>`, `like-<uuid>`), and
  it is the client's bookmark rather than our foreign key — an id whose row is
  since gone must not fail a write, it just scrolls to nothing.

  New table, so N-1 compatible: the running release neither reads nor writes it.
  """

  def change do
    create table(:mastodon_markers) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:organization_id, references(:organizations, on_delete: :delete_all))
      add(:timeline, :string, null: false)
      add(:last_read_id, :string, null: false)
      # Mastodon's own optimistic-concurrency counter, which clients read back.
      add(:version, :integer, null: false, default: 1)

      timestamps()
    end

    create(
      unique_index(:mastodon_markers, [:user_id, :timeline],
        where: "organization_id IS NULL",
        name: :mastodon_markers_member_timeline_index
      )
    )

    create(
      unique_index(:mastodon_markers, [:user_id, :organization_id, :timeline],
        where: "organization_id IS NOT NULL",
        name: :mastodon_markers_organization_timeline_index
      )
    )
  end
end
