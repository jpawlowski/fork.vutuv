defmodule Vutuv.CardDav.PushSubscription do
  @moduledoc """
  One device's WebDAV-Push registration for its owner's address book.

  A CardDAV client that supports WebDAV-Push `POST`s a `push-register` document
  to the collection, naming a Web Push endpoint of its own and the two keys
  that encrypt to it. We keep the row and, whenever the member's address book
  moves, send one small encrypted XML message there; the device then runs the
  ordinary `sync-collection` it would otherwise have run on a timer.

  The endpoint is a URL somebody else supplies and this server will POST to, so
  it carries the same SSRF pair as every other stored-then-fetched URL here:
  the cheap literal check in this changeset, and the resolving check
  `Vutuv.WebPush` runs again at send time, because a hostname that
  was public when the row was written can be re-pointed afterwards.
  """

  use VutuvWeb, :model

  alias Vutuv.Ssrf
  alias Vutuv.WebPush

  schema "carddav_push_subscriptions" do
    belongs_to(:user, Vutuv.Accounts.User)

    field(:push_resource, :string)
    field(:p256dh, :string)
    field(:auth_secret, :string)
    field(:expires_at, :utc_datetime)
    # The `users.carddav_revision` this device was last told about.
    field(:last_revision, :integer, default: 0)
    # The sweeper's clock, stamped on every outcome.
    field(:checked_at, :naive_datetime)

    timestamps()
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:push_resource, :p256dh, :auth_secret, :expires_at, :last_revision])
    |> validate_required([:push_resource, :p256dh, :auth_secret, :expires_at])
    # `push_resource` is a `:text` column on purpose; the keys are not, so they
    # are capped here rather than left to raise Postgres 22001.
    |> validate_length(:p256dh, max: 255)
    |> validate_length(:auth_secret, max: 255)
    |> validate_change(:p256dh, &validate_key(&1, &2, 65))
    |> validate_change(:auth_secret, &validate_key(&1, &2, 16))
    |> validate_change(:push_resource, &validate_endpoint/2)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Whether this registration is still live at `now`."
  def live?(%__MODULE__{expires_at: expires_at}, now \\ DateTime.utc_now()) do
    DateTime.compare(expires_at, now) == :gt
  end

  @doc "The shape `Vutuv.WebPush.send_body/2` expects."
  def target(%__MODULE__{} = subscription) do
    %{
      endpoint: subscription.push_resource,
      p256dh: subscription.p256dh,
      auth: subscription.auth_secret
    }
  end

  defp validate_endpoint(:push_resource, value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        if Ssrf.internal_host?(host),
          do: [push_resource: "must not point at a private, loopback or link-local address"],
          else: []

      _other ->
        [push_resource: "must be an https URL"]
    end
  end

  # Refused here rather than at delivery, for the reason the Mastodon
  # subscription gives: an unusable key stored once is not one failed push, it
  # is a device that stays silent forever with nobody able to say why.
  defp validate_key(field, value, bytes) do
    case WebPush.decode_key(value) do
      {:ok, decoded} when byte_size(decoded) == bytes -> []
      _undecodable_or_wrong_size -> [{field, "must be base64url of #{bytes} bytes"}]
    end
  end
end
