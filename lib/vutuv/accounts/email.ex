defmodule Vutuv.Accounts.Email do
  @moduledoc false

  use VutuvWeb, :model
  import Vutuv.ChangesetHelpers, only: [downcase_value: 1]

  alias Vutuv.Visibility

  schema "emails" do
    field(:value, :string)
    field(:md5sum, :string)
    # Privacy by default (GDPR Art. 25): an address is only shown to others
    # after the owner explicitly opts in (sign-up checkbox / email settings).
    #
    # Superseded by `visibility` below (issue #1521) and now a *derived mirror*
    # of it (`visibility == "everyone"`), kept only so the previous release keeps
    # working across a blue/green switch (expand/contract, see CLAUDE.md). It is
    # written by `sync_visibility/1`, never read for display. The follow-up
    # deploy drops it.
    field(:public?, :boolean, default: false)
    # Who may see this address: one of `Vutuv.Visibility.levels/0`
    # ("everyone" / "members" / "connected" / "private"). Bounded by
    # validate_inclusion against that list, which is why it needs no
    # varchar(255) length validation.
    #
    # Defaults to "private" for a struct the new code builds, matching the
    # `public?: false` default above — registration opts its address up to
    # "everyone" explicitly, exactly as it used to set `public?: true`.
    #
    # NULL is possible and meaningful in the database (the column is nullable
    # with no default on purpose, see the migration): it marks a row the *old*
    # release inserted, which knew only `public?`. Never read the field raw —
    # go through `visibility_of/1`, which resolves that case.
    field(:visibility, :string, default: "private")
    # A Work/Personal/Other label, mirroring PhoneNumber.number_type. Defaults
    # to "Other" (the unspecified bucket the registration/backfill assign).
    field(:email_type, :string, default: "Other")
    # Set by a failure DSN (Vutuv.Notifications.Bounces), cleared by a
    # successful login PIN through the address. Never cast from params.
    field(:undeliverable_at, :naive_datetime)
    # The owner's chosen display order. Set programmatically (on create and via
    # the reorder/move actions), never cast from user params. NULLs sort last so
    # legacy rows fall back to creation order until reordered. See Vutuv.Ordering.
    field(:position, :integer)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  # Private first: most people sign up with their personal address, and the
  # first radio is the one that is preselected.
  @email_types ~w(Personal Work Other)

  @doc "The allowed `email_type` values, in the order the forms list them."
  def email_types, do: @email_types

  @doc "Email addresses in the owner's chosen order (see `Vutuv.Ordering`)."
  def ordered(query \\ __MODULE__), do: Vutuv.Ordering.by_position(query)

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:value, :public?, :visibility, :email_type])
    |> validate_required([:value, :email_type])
    |> validate_inclusion(:email_type, @email_types)
    |> sync_visibility()
    |> downcase_value
    |> validate_format(:value, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    # varchar(255) column and the RFC 5321 254-char address cap: an oversized
    # address must fail as a changeset error, never as a raised Postgres 22001.
    |> validate_length(:value, max: 254)
    |> unique_constraint(:value)
    |> fill_md5sum
  end

  # The address itself is an identity and may only be set through the
  # PIN-verified create/confirm flow, so editing is limited to the visibility
  # and the Work/Personal/Other label (both pure metadata).
  def update_changeset(model, params \\ %{}) do
    model
    |> cast(params, [:public?, :visibility, :email_type])
    |> validate_inclusion(:email_type, @email_types)
    |> sync_visibility()
  end

  @doc """
  The rung this address sits on, resolving the one case the column cannot
  express: `nil` means the row was written by the previous release, which knew
  only `public?`, so the boolean decides (issue #1521, expand/contract). Every
  display path goes through this rather than reading `visibility` raw.
  """
  def visibility_of(%__MODULE__{visibility: level}) when is_binary(level), do: level
  def visibility_of(%__MODULE__{public?: true}), do: "everyone"
  def visibility_of(%__MODULE__{}), do: "private"

  # Keeps the four-rung `visibility` and the legacy `public?` boolean agreeing,
  # whichever of the two a form submitted, and validates the rung.
  #
  # Both are cast because two live forms write them: the settings form submits
  # the four-way select, while the **sign-up** form still submits its single
  # "show my address on my profile" checkbox (page/index.html.heex) — turning
  # that checkbox into a four-way select on the registration page would be a
  # worse trade than mapping it. `visibility` wins when both change, since it is
  # the richer control; otherwise the boolean is widened to a rung.
  defp sync_visibility(changeset) do
    changeset =
      case {get_change(changeset, :visibility), get_change(changeset, :public?)} do
        {nil, nil} -> changeset
        {nil, public?} -> put_change(changeset, :visibility, boolean_rung(public?))
        {level, _public?} -> put_change(changeset, :public?, level == "everyone")
      end

    validate_inclusion(changeset, :visibility, Visibility.levels())
  end

  defp boolean_rung(true), do: "everyone"
  defp boolean_rung(_false_or_nil), do: "private"

  def fill_md5sum(changeset) do
    if value = get_change(changeset, :value) do
      md5sum =
        :crypto.hash(:md5, value)
        |> Base.encode16()
        |> String.downcase()

      put_change(changeset, :md5sum, md5sum)
    else
      changeset
    end
  end

  def can_delete?(id) do
    Vutuv.Repo.one(
      from(u in Vutuv.Accounts.Email, where: u.user_id == ^id, select: count("value"))
    ) > 1
  end
end
