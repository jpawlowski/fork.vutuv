defmodule Vutuv.Profiles.PhoneNumber do
  @moduledoc false

  use VutuvWeb, :model

  alias Vutuv.Visibility

  schema "phone_numbers" do
    field(:value, :string)
    field(:number_type, :string)
    # Who may see this number: one of `Vutuv.Visibility.levels/0` ("everyone" /
    # "members" / "connected" / "private"), issue #1521. Bounded by
    # validate_inclusion against that list, so it needs no varchar(255) length
    # validation. NOT NULL in the database, defaulted there as well, so a row
    # the previous release inserts across a blue/green switch still gets a rung.
    #
    # Defaults to "private", like `Email.visibility`: before this column existed
    # every number was public without anybody choosing that, which is the
    # data-protection problem the ladder exists to fix — so a number the owner
    # has said nothing about is shown to nobody, and reaching an audience is
    # always an explicit act. Resolve for display through `visibility_of/1`.
    field(:visibility, :string, default: "private")
    # The owner's chosen display order. Set programmatically (on create and via
    # the reorder/move actions), never cast from user params. NULLs sort last so
    # legacy rows fall back to creation order until reordered. See Vutuv.Ordering.
    field(:position, :integer)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @doc "Phone numbers in the owner's chosen order (see `Vutuv.Ordering`)."
  def ordered(query \\ __MODULE__), do: Vutuv.Ordering.by_position(query)

  @format_message ~s/Please enter a valid phone number/
  @requred_message ~s/This field is required/

  # The allowed `number_type` labels, in the order the HTML form lists them: a
  # private/work × landline/mobile matrix (issue #948), plus Fax. "Home"/"Cell"
  # are the private landline / mobile, "Work"/"Work Cell" the work landline /
  # mobile. Fax is kept because it is still relevant in some regions (dropping
  # it was an overcorrection). Mirrors Email.email_types: enforced in the
  # schema, not just the <select>.
  @number_types ["Home", "Cell", "Work", "Work Cell", "Fax"]

  @doc "The allowed `number_type` values, in the order the forms list them."
  def number_types, do: @number_types

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:value, :number_type, :visibility])
    |> validate_required([:value, :number_type], message: @requred_message)
    |> validate_inclusion(:number_type, @number_types)
    |> validate_inclusion(:visibility, Visibility.levels())
    |> update_change(:value, &String.trim/1)
    |> normalize_value()
  end

  @doc """
  The rung this number sits on. The column is NOT NULL, so this only guards an
  in-memory struct that never went through the changeset; it exists so callers
  can treat phone numbers and email addresses through one interface (see
  `Vutuv.Accounts.Email.visibility_of/1`, which has real work to do).
  """
  def visibility_of(%__MODULE__{visibility: level}) when is_binary(level), do: level
  def visibility_of(%__MODULE__{}), do: "private"

  # Rewrites a typed number to canonical international format (`0261-123456` ->
  # `+49 261 123456`) and rejects anything that is not a real phone number, so
  # only validated, normalized values reach the database. See
  # `Vutuv.Phone.normalize/1`.
  defp normalize_value(changeset) do
    case get_change(changeset, :value) do
      value when is_binary(value) ->
        case Vutuv.Phone.normalize(value) do
          {:ok, normalized} -> put_change(changeset, :value, normalized)
          :error -> add_error(changeset, :value, @format_message)
        end

      _ ->
        changeset
    end
  end
end
