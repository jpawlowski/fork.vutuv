defmodule Vutuv.Profiles.Address do
  @moduledoc false

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [trim_fields: 2]

  alias Vutuv.Visibility

  @string_fields [
    :description,
    :line_1,
    :line_2,
    :line_3,
    :line_4,
    :zip_code,
    :city,
    :state,
    :country
  ]

  schema "addresses" do
    field(:description, :string)
    field(:line_1, :string)
    field(:line_2, :string)
    field(:line_3, :string)
    field(:line_4, :string)
    field(:zip_code, :string)
    field(:city, :string)
    field(:state, :string)
    field(:country, :string)
    # The owner's chosen display order. Set programmatically (on create and via
    # the reorder/move actions), never cast from user params. NULLs sort last so
    # legacy rows fall back to creation order until reordered. See Vutuv.Ordering.
    field(:position, :integer)
    # Who may see this address: one of `Vutuv.Visibility.levels/0` ("everyone" /
    # "members" / "connected" / "private"), issue #1521 — the same ladder the
    # email address and the phone number sit on, resolved through the same
    # `Vutuv.Accounts.contact_scope/2`. Bounded by validate_inclusion, so it needs
    # no varchar(255) length validation. NOT NULL and defaulted in the database.
    #
    # Defaults to "private", like its two siblings and for the same reason: before
    # this column existed every address was public without anybody choosing that,
    # and a home address is if anything the most sensitive of the three. Resolve
    # for display through `visibility_of/1`.
    field(:visibility, :string, default: "private")

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @doc "Addresses in the owner's chosen order (see `Vutuv.Ordering`)."
  def ordered(query \\ __MODULE__), do: Vutuv.Ordering.by_position(query)

  @doc """
  The deliberately lax changeset behind the one-time welcome page
  (`/system/welcome`), where a brand-new member is asked where they are before
  they have any reason to trust us with a full address.

  It casts only the coarse location — the `description` label ("Private" /
  "Work"), `zip_code`, `city` and `country` — and requires **nothing**: a lone
  city, a lone postal code and a lone country are each a perfectly good answer,
  and an empty form is simply no address at all (`location_given?/1` is what
  the caller checks before inserting). Only the column lengths are enforced, so
  the save can never raise Postgres 22001.
  """
  def welcome_changeset(model, params) do
    fields = [:description, :zip_code, :city, :country]

    model
    |> cast(params, fields)
    |> trim_fields(fields)
    |> validate_length(:description, max: 100)
    |> validate_length(:zip_code, max: 32)
    |> validate_length(:city, max: 100)
    |> validate_length(:country, max: 100)
  end

  @doc """
  Whether a welcome changeset carries an actual location (any one of postal
  code, city or country). The label alone is not a location, so a member who
  only picks "Private" and types nothing stores no address.
  """
  def location_given?(%Ecto.Changeset{} = changeset) do
    Enum.any?([:zip_code, :city, :country], fn field ->
      case get_field(changeset, field) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  @doc """
  The rung this address sits on. The column is NOT NULL, so this only guards an
  in-memory struct that never went through a changeset; it exists so callers can
  treat all three contact channels through one interface (see
  `Vutuv.Accounts.Email.visibility_of/1`, which has real work to do).
  """
  def visibility_of(%__MODULE__{visibility: level}) when is_binary(level), do: level
  def visibility_of(%__MODULE__{}), do: "private"

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:visibility | @string_fields])
    |> trim_fields(@string_fields)
    |> validate_required([:description, :country])
    |> validate_inclusion(:visibility, Visibility.levels())
    |> validate_length(:description, max: 100)
    |> validate_length(:line_1, max: 255)
    |> validate_length(:line_2, max: 255)
    |> validate_length(:line_3, max: 255)
    |> validate_length(:line_4, max: 255)
    |> validate_length(:zip_code, max: 32)
    |> validate_length(:city, max: 100)
    |> validate_length(:state, max: 100)
    |> validate_length(:country, max: 100)
  end
end
