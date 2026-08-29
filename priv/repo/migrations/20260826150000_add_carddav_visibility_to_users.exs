defmodule Vutuv.Repo.Migrations.AddCarddavVisibilityToUsers do
  use Ecto.Migration

  @moduledoc """
  The other half of the CardDAV address book (issue #1705): who may carry *my*
  card in theirs.

  `users.carddav_sharing` is the subscriber's question — which of my contacts do
  I publish to my own devices — and it is `"off"` for everybody, because what it
  publishes belongs to other people. This column is the mirror image and the
  member's own data, so it is generous by default: `"followers"`, meaning
  anybody who follows me may keep my card. An address book that is empty until
  every single contact has opted in is not an address book, and nothing here
  leaves the anonymous public view of a profile that any visitor already sees.

  The deliberate opt-out is the point: `"mutual"` narrows it to people I follow
  back, `"nobody"` withdraws entirely.

  **It outranks the subscriber's setting.** Whoever the data is about decides:
  a member set to `"nobody"` is absent from every book, however wide the other
  side has opened theirs and whatever they marked.

  N-1 safe: one addition with a default the previous release neither reads nor
  writes.
  """

  def change do
    alter table(:users) do
      add(:carddav_visibility, :string, null: false, default: "followers")
    end
  end
end
