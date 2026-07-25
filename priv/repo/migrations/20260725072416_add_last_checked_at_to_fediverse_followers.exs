defmodule Vutuv.Repo.Migrations.AddLastCheckedAtToFediverseFollowers do
  use Ecto.Migration

  @moduledoc """
  When this follower's remote actor document was last re-fetched by
  Vutuv.Fediverse.FollowerPruner (issue #1072). NULL = never checked, so every
  row written before this migration is due at once and the pruner works
  through them oldest-first, in small batches. The index carries that ordering.
  Plain addition, N-1 safe.
  """

  def change do
    alter table(:fediverse_followers) do
      add(:last_checked_at, :naive_datetime)
    end

    create(index(:fediverse_followers, [:last_checked_at]))
  end
end
