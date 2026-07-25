defmodule Vutuv.Repo.AudienceGroupsDroppedTest do
  @moduledoc """
  The contract half of the audience-Groups removal.

  Commit 02589063 (2026-06-13) deleted the feature's code but deliberately kept
  its tables (`groups`, `memberships`) and the `post_denials.group_id` column
  with its RESTRICT foreign key, so the release still serving traffic during
  that blue/green deploy kept working (the N-1 rule). That window closed with
  the very next deploy; `drop_audience_groups` finally removes them.

  This guards the drop against a re-introduction by an old branch's migration
  being replayed, and pins why `Vutuv.Accounts.delete_user/1` no longer needs
  to clear the account's posts before the cascade: that RESTRICT FK was the
  only thing that could have blocked the delete, and it is gone.
  """
  use Vutuv.DataCase, async: true

  @dropped_tables ~w(groups memberships)

  test "the audience-Groups tables are gone" do
    for table <- @dropped_tables do
      refute table_exists?(table),
             "#{table} is a dropped audience-Groups table — nothing may recreate it"
    end
  end

  test "post_denials no longer carries group_id" do
    refute column_exists?("post_denials", "group_id"),
           "post_denials.group_id belonged to the removed audience-Groups feature"
  end

  test "a denial still targets exactly one user or one wildcard" do
    columns = table_columns("post_denials")

    assert "denied_user_id" in columns
    assert "wildcard" in columns
  end

  test "nothing references the dropped tables by a foreign key" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT cl.relname, c.conname
        FROM pg_constraint c
        JOIN pg_class cl ON cl.oid = c.conrelid
        JOIN pg_class parent ON parent.oid = c.confrelid
        WHERE c.contype = 'f' AND parent.relname = ANY($1)
        """,
        [@dropped_tables]
      )

    assert rows == [],
           "dangling FKs to a dropped audience-Groups table: #{inspect(rows)}"
  end

  defp table_exists?(table) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables " <>
          "WHERE table_schema = 'public' AND table_name = $1",
        [table]
      )

    count > 0
  end

  defp column_exists?(table, column), do: column in table_columns(table)

  defp table_columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1",
        [table]
      )

    List.flatten(rows)
  end
end
