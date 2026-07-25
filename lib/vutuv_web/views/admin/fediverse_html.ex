defmodule VutuvWeb.Admin.FediverseHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers, only: [member_name: 1]

  embed_templates("../../templates/admin/fediverse/*")

  @doc """
  What a takedown row means, in words. The stored `action` values are the closed
  set `Vutuv.Fediverse.NoteEvent.actions/0` holds; an unknown one still renders
  something rather than leaking a raw string at the operator.
  """
  def note_event_label(%{action: "reported"}), do: gettext("Reported as not appropriate")
  def note_event_label(%{action: "removed_by_member"}), do: gettext("Removed by the member")
  def note_event_label(_event), do: gettext("Taken down")
end
