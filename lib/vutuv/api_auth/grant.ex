defmodule Vutuv.ApiAuth.Grant do
  @moduledoc """
  A user's authorization of an app: which scopes they granted, once per
  user × app (written by the consent flow, `Vutuv.ApiAuth.OAuth`).
  Revoking sets `revoked_at` and kills the grant's tokens; re-consent
  reuses the row. The "Connected apps" page lists these.
  """

  use VutuvWeb, :model

  schema "oauth_grants" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:app, Vutuv.ApiAuth.App)

    field(:scopes, {:array, :string}, default: [])
    field(:revoked_at, :utc_datetime)

    # Filled by `Vutuv.ApiAuth.list_grants/1` for the Connected apps page.
    # Virtual because they are a question about how this row is *shown* — when
    # the member connected the app, and which devices still hold a live token
    # under it — rather than facts about the grant row itself.
    field(:connected_at, :naive_datetime, virtual: true)
    field(:devices, {:array, :string}, virtual: true, default: [])

    timestamps()
  end
end
