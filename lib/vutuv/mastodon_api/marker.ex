defmodule Vutuv.MastodonApi.Marker do
  @moduledoc """
  One client's reading position in one timeline (see `Vutuv.MastodonApi.Markers`).

  `last_read_id` is a `:string` and not a reference on purpose: the id a client
  hands back may be a derived one this adapter mints (`remote-<uuid>`,
  `like-<uuid>`), and a bookmark whose entry is gone must not fail a write.
  """

  use VutuvWeb, :model

  schema "mastodon_markers" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)

    field(:timeline, :string)
    field(:last_read_id, :string)
    field(:version, :integer, default: 1)

    timestamps()
  end
end
