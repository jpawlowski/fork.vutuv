defmodule Vutuv.Repo.Migrations.AddVisibilityToAddresses do
  use Ecto.Migration

  # Postal addresses join the contact ladder (issue #1521), so all three contact
  # channels — email address, phone number, postal address — carry the same four
  # rungs from `Vutuv.Visibility` and resolve through the same
  # `Vutuv.Accounts.contact_scope/2`. Offering the choice for one kind of contact
  # detail and not the others is the inconsistency this closes.
  #
  # Same shape and same reasoning as `phone_numbers.visibility`: NOT NULL with a
  # database default of "private", so existing rows take that default in the same
  # metadata-only ALTER (PG 11+) and a row the previous release inserts across a
  # blue/green switch lands there too.
  #
  # And the same justification for starting at "private": `addresses` had no
  # visibility column either, so every stored address was public without anybody
  # choosing that — the form offered no choice. A home address is if anything more
  # sensitive than a phone number, so the mitigation argument (GDPR Art. 25, data
  # protection by default) applies at least as strongly. An address becomes
  # visible again only through an explicit choice by its owner.
  #
  # No `public?`-style legacy column exists here, so unlike `emails` this needs no
  # expand/contract mirror — the column is the single source from the first day.
  def up do
    alter table(:addresses) do
      add(:visibility, :string, null: false, default: "private")
    end
  end

  def down do
    alter table(:addresses) do
      remove(:visibility)
    end
  end
end
