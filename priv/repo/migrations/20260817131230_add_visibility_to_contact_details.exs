defmodule Vutuv.Repo.Migrations.AddVisibilityToContactDetails do
  use Ecto.Migration

  # The audience ladder for contact details (issue #1521): "everyone" /
  # "members" / "connected" / "private", bounded in the schemas by
  # `Vutuv.Visibility.levels/0` — a validate_inclusion against that list, which
  # is why neither column needs the varchar(255) length validation the
  # free-text `:string` columns carry.
  #
  # ## Why phone numbers start at "private", and emails do not
  #
  # `phone_numbers` had **no visibility column at all**, so every stored number
  # was public — and that was never a decision anybody made: the form offered no
  # choice, so no member ever consented to publishing their number to the open
  # internet. Members arrive with the expectation other platforms set (a number
  # is shared with contacts, not with crawlers) and vutuv did not meet it. We
  # treat that as a data-protection breach rather than a missing feature, so the
  # backfill is a mitigation under GDPR Art. 25 (data protection **by default**)
  # and a direct scam-call countermeasure — not a product preference. Every
  # existing number therefore lands on the narrowest rung, "private", and only
  # becomes visible again through an explicit choice by its owner.
  #
  # `emails` are the opposite case: `public?` already was a deliberate,
  # member-set flag, so overwriting it would destroy a real decision. It maps
  # straight across — true -> "everyone", false -> "private" — and nobody's
  # address changes audience.
  #
  # ## N-1 compatibility (blue/green, see CLAUDE.md)
  #
  # Migrations run while the previous release still serves traffic, so both
  # columns have to be harmless to code that has never heard of them.
  #
  #   * `phone_numbers.visibility` is NOT NULL with a **default of "private"**.
  #     Existing rows take that default in the same metadata-only ALTER (PG 11+),
  #     which is the backfill. A row the old release inserts during the switch
  #     window also lands on "private": the reasoning above says an un-chosen
  #     number must not be public, and that holds for a number added sixty
  #     seconds before the switch just as much as for one added last year.
  #   * `emails.visibility` is **nullable with no default** on purpose. A NULL
  #     means "written by the old release, which only knew `public?`", and the
  #     read path resolves it through `public?`
  #     (`Vutuv.Accounts.Email.visibility_of/1`) instead of guessing. That keeps
  #     a mid-window registration — which sets `public?: true` — public, which no
  #     single column default could have done correctly.
  #
  # `public?` is deliberately left in place and kept in sync by the new release
  # (expand/contract): the currently deployed release still reads it. Dropping it
  # and making `emails.visibility` NOT NULL is a separate, later deploy.
  def up do
    alter table(:phone_numbers) do
      add(:visibility, :string, null: false, default: "private")
    end

    alter table(:emails) do
      add(:visibility, :string)
    end

    execute("""
    UPDATE emails
    SET visibility = CASE WHEN "public?" THEN 'everyone' ELSE 'private' END
    """)
  end

  def down do
    alter table(:phone_numbers) do
      remove(:visibility)
    end

    alter table(:emails) do
      remove(:visibility)
    end
  end
end
