defmodule Vutuv.Repo.LegacyLocaleTablesDroppedTest do
  @moduledoc """
  The 2016 `locales` / `exonyms` tables are gone (`drop_legacy_locale_tables`).

  Spoken languages live in `Vutuv.Languages` — a curated list in code, stored
  per member in `languages` as an ISO 639-1 code, with the display name coming
  from Gettext in the viewer's locale. That is what replaced the old
  language-names-as-data design, so nothing may reintroduce it.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.Language

  @dropped_tables ~w(locales exonyms)

  test "the legacy language tables are gone" do
    for table <- @dropped_tables do
      refute table_exists?(table),
             "#{table} is a dropped 2016 language table — Vutuv.Languages replaced it"
    end
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

    assert rows == [], "dangling FKs to a dropped language table: #{inspect(rows)}"
  end

  test "a member's languages still resolve their name without the dropped tables" do
    user = insert(:user)

    {:ok, language} =
      %Language{user_id: user.id}
      |> Language.changeset(%{"language_code" => "de", "proficiency" => "native"})
      |> Repo.insert()

    assert language.language_code == "de"
    # The name comes from Vutuv.Languages (code + Gettext), never from a table.
    assert Vutuv.Languages.name("de") in ["German", "Deutsch"]
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
end
