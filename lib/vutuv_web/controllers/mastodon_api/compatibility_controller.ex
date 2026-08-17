defmodule VutuvWeb.MastodonApi.CompatibilityController do
  @moduledoc "Small read-only Mastodon resources clients request during startup."

  use VutuvWeb, :controller

  alias Vutuv.MastodonApi.Markers
  alias Vutuv.MastodonApi.Presenter

  def preferences(conn, _params) do
    json(conn, %{
      "posting:default:visibility" => "public",
      "posting:default:sensitive" => false,
      "posting:default:language" => nil,
      "reading:expand:media" => "default",
      "reading:expand:spoilers" => false
    })
  end

  @doc """
  Where this client left off reading (`GET /api/v1/markers`).

  Answered a bare `{}` until now, with no `POST` to fill it — so a position was
  never stored and never restored, and relaunching an app dropped its timeline
  back to whatever it could fetch.
  """
  def markers(conn, params) do
    json(conn, rendered_markers(Markers.get(identity(conn), asked_for(params))))
  end

  @doc "Records the position (`POST /api/v1/markers`)."
  def put_markers(conn, params) do
    json(conn, rendered_markers(Markers.put(identity(conn), params)))
  end

  def empty(conn, _params), do: json(conn, [])

  # A page identity's position is the page's, so the marker is keyed on the
  # organization rather than on whoever happens to be reading for it.
  defp identity(conn) do
    case conn.assigns.current_organization do
      nil -> conn.assigns.current_user
      organization -> {conn.assigns.current_user, organization}
    end
  end

  # `timeline[]=home&timeline[]=notifications`. Plug gives the repeated
  # parameter as a list under `timeline`; a single one arrives as a bare string.
  defp asked_for(params), do: List.wrap(params["timeline"] || params["timeline[]"])

  defp rendered_markers(markers) do
    Map.new(markers, fn {timeline, marker} ->
      {timeline,
       %{
         last_read_id: marker.last_read_id,
         version: marker.version,
         updated_at: Presenter.timestamp(marker.updated_at)
       }}
    end)
  end
end
