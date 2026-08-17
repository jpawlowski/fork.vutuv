defmodule Vutuv.Visibility do
  @moduledoc """
  The shared audience ladder for a single piece of profile information (issue
  #1521): who, other than the owner, gets to see it.

  Four rungs, widest first — the order every form lists them in:

      "everyone"   the public profile and its crawlable siblings
      "members"    anyone signed in to this installation
      "connected"  the people the owner is *vernetzt* with (mutual follow)
      "private"    the owner alone

  The ladder is deliberately **monotone**: each rung is a strict subset of the
  one above it, so "narrower" always means "fewer people" and a member never
  has to reason about two audiences that merely overlap.

  ## Why there is no "my followers" rung

  A one-directional follow is not a mutual decision: anybody can create one by
  clicking a button. A "my followers may see it" rung would therefore let a
  stranger **grant themselves** access to a phone number — which is exactly the
  scam-call problem this ladder exists to solve. `"connected"` needs a follow
  from *both* sides, so the owner has always taken part. That is the "contract"
  vutuv has; it needs no LinkedIn-style confirmation dialog, because both
  people already clicked.

  ## Resolving it

  `scope/2` answers "which rungs may this viewer see" **once** per render, so a
  page with a dozen contact rows pays for the mutual-follow lookup a single
  time rather than per row. Call sites then filter on the *column* with
  `visibility in ^scope` — never by pattern-matching a preloaded association,
  and never with a `NOT IN` (see the NULL-trap note in CLAUDE.md).

  The subtractive layer (`Vutuv.Accounts.ViewerExclusion`, issue #938) is
  applied by `Vutuv.Accounts.contact_scope/2`, which composes this module's
  level maths with the owner's exclusion list. Subtracting never adds, so it
  can only ever narrow what `scope/2` returned.
  """

  # `gettext/1` macro so the labels and hints are picked up by
  # `mix gettext.extract` (a runtime `Gettext.gettext/2` call never is).
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Social

  @levels ~w(everyone members connected private)

  # The rungs a viewer of each kind may see, widest first. Keyed by the verdict
  # `scope/2` reaches, so the ladder's shape lives in exactly one place.
  @anonymous_scope ~w(everyone)
  @member_scope ~w(everyone members)
  @connected_scope ~w(everyone members connected)

  @doc "The allowed `visibility` values, in the order the forms list them."
  def levels, do: @levels

  @doc "Whether `level` is one of the four rungs."
  def valid?(level), do: level in @levels

  @doc "The owner-facing label for a rung, as the forms and status lines show it."
  def label("everyone"), do: gettext("Everyone")
  def label("members"), do: gettext("Signed-in members")
  def label("connected"), do: gettext("People I am connected with")
  def label("private"), do: gettext("Only me")
  def label(_other), do: label("everyone")

  @doc """
  The one-sentence explanation shown under a rung in the form. Stefan's first
  condition on issue #1521 was that it has to be clear to a non-technical
  member what a change *means*, so every rung says who that is in plain words —
  the label alone ("Signed-in members") does not carry it.
  """
  def hint("everyone"),
    do:
      gettext(
        "On your public profile, and in the Markdown, text, JSON, XML and vCard versions of it."
      )

  def hint("members"), do: gettext("Only for people signed in to this site.")

  def hint("connected"),
    do: gettext("Only for people you follow who also follow you back.")

  def hint("private"), do: gettext("Only for you. Nobody else, and no download contains it.")

  def hint(_other), do: hint("everyone")

  @doc "`{label, value}` pairs for a form select, widest audience first."
  def options, do: Enum.map(@levels, &{label(&1), &1})

  @doc """
  The owner-facing sentence behind the lock glyph on a restricted contact row,
  naming **who** that row reaches. Written in the owner's voice ("you"), which is
  why the profile shows these markers to the owner alone.

  `nil` for `"everyone"`: an unrestricted row carries no marker, so there is
  nothing to say — and a call site rendering the note on every row would put an
  empty tooltip on the public ones (the issue #880 shape).
  """
  def visibility_note("everyone"), do: nil
  def visibility_note("members"), do: gettext("Only visible to signed-in members")

  def visibility_note("connected"),
    do: gettext("Only visible to people you are connected with")

  # Reuses the msgid the contact card has always shown on an owner-only address,
  # in the same voice, so its translation stays correct.
  def visibility_note("private"), do: gettext("Only visible to you")
  def visibility_note(_other), do: nil

  @doc """
  The rungs `viewer` may see of `owner`'s information, resolved in one call.

  A `nil` viewer is the anonymous public view — the logged-out visitor, the
  crawler and the `.md`/`.txt`/`.json`/`.xml`/`.vcf` siblings — and sees only
  `"everyone"`. The owner sees all four, so their own editor and their own
  profile view never hide anything from them.

  Costs one mutual-follow lookup for a signed-in stranger, and nothing at all
  for the anonymous and owner cases.
  """
  def scope(%User{}, nil), do: @anonymous_scope
  def scope(%User{id: same}, %User{id: same}), do: @levels

  def scope(%User{id: owner_id}, %User{id: viewer_id}) do
    if Social.connected?(owner_id, viewer_id), do: @connected_scope, else: @member_scope
  end

  @doc """
  Whether a single `level` is visible to `viewer`. For one lone value; a list of
  rows should resolve `scope/2` once and filter on the column instead.

  An unknown or `nil` level is treated as `"everyone"`, matching `label/1`: the
  fallback has to be what the data meant *before* the column existed, and for
  both phone numbers and public email addresses that was public.
  """
  def visible_to?(level, %User{} = owner, viewer) do
    level = if valid?(level), do: level, else: "everyone"
    level in scope(owner, viewer)
  end
end
