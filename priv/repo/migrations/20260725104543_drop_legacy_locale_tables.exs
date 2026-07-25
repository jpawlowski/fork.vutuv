defmodule Vutuv.Repo.Migrations.DropLegacyLocaleTables do
  use Ecto.Migration

  @moduledoc """
  Drops `exonyms` and `locales`, the 2016 language tables the current spoken
  languages feature superseded.

  The old design kept the world's languages as data: `locales` held the ISO
  639-1 code plus its endonym (the language's name in itself — "Deutsch",
  "日本語"), seeded by `populate_locales`, and `exonyms` was to hold each
  language's name *in another language*, so a name could be shown translated.
  It never received a row.

  Spoken languages were rebuilt around `Vutuv.Languages` (issue #865): a
  curated, finite list in code, stored per member in `languages` as a bare ISO
  639-1 code, with the display name coming from Gettext in the viewer's own
  locale. That replaced both tables — a translated language name is now a
  `.po` entry, which is what `exonyms` was reaching for. Nothing has read
  either table since; no Ecto schema maps them (the `Vutuv.Accounts.Locale`
  and `Exonym` modules are long gone) and no query names them.

  Nothing else points a foreign key at either table, and the two FKs being
  removed are the ones `exonyms` holds into `locales`. Both drops are plain
  removals of tables the running code never touches, so this is N-1 safe on
  its own: the currently deployed release keeps working unchanged.

  The row counts are printed first, so the deploy log records what was there.
  """

  @counted [
    {"locales", "SELECT count(*) FROM locales"},
    {"exonyms", "SELECT count(*) FROM exonyms"}
  ]

  def up do
    for {label, sql} <- @counted do
      %{rows: [[count]]} = repo().query!(sql, [])
      IO.puts("drop_legacy_locale_tables: #{label}: #{count}")
    end

    # exonyms first: it is the only thing holding a FK into locales.
    drop(table(:exonyms))
    drop(table(:locales))
  end

  def down do
    # Best-effort: the empty schema comes back. The `locales` rows are not
    # restored here — they are the seed data of `populate_locales`, which is
    # where that list lives if it is ever wanted again.
    create table(:locales) do
      add(:value, :string)
      add(:endonym, :string)

      timestamps()
    end

    create(unique_index(:locales, [:value]))

    create table(:exonyms) do
      add(:value, :string)
      add(:locale_id, references(:locales, on_delete: :nothing))
      add(:exonym_locale_id, references(:locales, on_delete: :nothing))

      timestamps()
    end

    create(unique_index(:exonyms, [:value, :locale_id]))
  end
end
