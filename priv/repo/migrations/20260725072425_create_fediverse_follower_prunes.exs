defmodule Vutuv.Repo.Migrations.CreateFediverseFollowerPrunes do
  use Ecto.Migration

  @moduledoc """
  One row per remote follower dropped because its account is gone (issue
  #1072): the member who lost the follower, the remote server it lived on and
  the HTTP status that proved it (404 or 410). Deliberately does NOT store the
  remote actor URI — the point of the pruning is to stop holding an identifier
  of somebody who deleted their account, so the ledger keeps only what the
  nightly Tagesbericht needs to make a mass-prune visible. Plain addition,
  N-1 safe.
  """

  def change do
    create table(:fediverse_follower_prunes) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:host, :string, null: false)
      add(:status, :integer, null: false)

      timestamps()
    end

    create(index(:fediverse_follower_prunes, [:inserted_at]))
    create(index(:fediverse_follower_prunes, [:user_id]))
  end
end
