defmodule Vutuv.Repo.Migrations.AddUserAgentToApiTokens do
  use Ecto.Migration

  @moduledoc """
  What the Connected apps page could not say: which device a token was minted
  from.

  A member sees several rows named "Ivory" because a Mastodon client registers
  a **new** OAuth app per install, and with neither a time nor a device on the
  row there was no way to tell one from another — so there was no way to
  withdraw the right one either.

  `text`, not varchar(255): a User-Agent is a remote client's string and not
  ours to bound (the same reasoning as `fediverse_followers.inbox_uri`). It is
  capped on the way in all the same, in `Vutuv.ApiAuth`, so a client cannot
  push an unbounded body into the column.

  Plain nullable addition, so it is N-1 compatible: the running release neither
  reads nor writes it.
  """

  def change do
    alter table(:api_tokens) do
      add(:user_agent, :text)
    end
  end
end
