defmodule Vutuv.Repo.Migrations.AddVcardDownloadToUsers do
  use Ecto.Migration

  @moduledoc """
  Who may download this member's profile as a vCard (issue #1705).

  The sibling of `carddav_visibility`, and it needs to exist for that one to
  mean anything: withdrawing from every address book while a one-click `.vcf`
  button sits on the profile is half a promise. Two settings rather than one,
  because they are not the same act — a subscription keeps the card up to date
  on somebody's device forever, a download is one file, once, of what the page
  already shows.

  Which is also why the levels differ: `"everyone"` is the default here and
  keeps today's behaviour exactly, an anonymous public download. Narrowing it
  to `"followers"` needs a signed-in viewer, and `"nobody"` takes the button
  and the URL away. Defaulting to anything narrower would quietly remove a
  public affordance from every existing member.

  N-1 safe: one addition with a default the previous release neither reads nor
  writes.
  """

  def change do
    alter table(:users) do
      add(:vcard_download, :string, null: false, default: "everyone")
    end
  end
end
