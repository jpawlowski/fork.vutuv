defmodule VutuvWeb.FediverseFollowersLive do
  @moduledoc """
  The member's own remote-follower browser (`/settings/fediverse/followers`).

  `/settings/fediverse` answers "do I take part at all"; this page answers "who
  are these people". It used to be a flat list of the 50 most recent rows on
  that page, which reads fine at four followers and not at all at ten thousand:
  no way to look someone up, no way to see when they arrived, no way past the
  first fifty. So the full list is its own page and its own **table**: search as
  you type (display name, handle, server, or a whole `@user@server` handle
  pasted out of a Mastodon profile), a server filter, three sortable columns
  (Account / Server / Following since) and numbered paging.

  Filter, sort and page live in the **URL** (`push_patch`), so a particular view
  is shareable and the back button restores it; `handle_params/3` is the single
  loader and the query work stays in `Vutuv.Fediverse` (`follower_filters/1`,
  `count_followers/2`, `list_followers_page/4`, `follower_hosts/2`).

  Owner-only by construction: it lives in the `/settings` scope, reads only
  `current_user`'s rows, and a member who does not federate is sent back to
  `/settings/fediverse`, where the switch is.
  """

  use VutuvWeb, :live_view

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Pages

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if Fediverse.federated?(user) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Followers from other networks"))
       |> assign(:user, user)
       |> assign(:total_followers, Fediverse.follower_count(user))
       |> assign(:hosts, Fediverse.follower_hosts(user))}
    else
      {:ok, push_navigate(socket, to: ~p"/settings/fediverse")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.user
    filters = Fediverse.follower_filters(params)
    per_page = Fediverse.followers_per_page()
    total = Fediverse.count_followers(user, filters)
    page = Pages.effective_page(params, total, per_page)

    followers =
      Fediverse.list_followers_page(user, filters, %{"page" => page},
        total: total,
        per_page: per_page
      )

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:total, total)
     |> assign(:page, page)
     |> assign(:per_page, per_page)
     |> assign(:followers, followers)}
  end

  # ── Events (every one just rewrites the URL; handle_params reloads) ──

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, patch(socket, %{"q" => params["q"], "server" => params["server"]})}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    filters = socket.assigns.filters

    dir =
      if filters.sort == col,
        do: flip(filters.dir),
        else: Fediverse.follower_default_dir(col)

    {:noreply, patch(socket, %{"sort" => col, "dir" => dir})}
  end

  # A server name in a row is a filter you can click: at ten thousand followers
  # "show me everyone else from this server" is the question the list raises.
  def handle_event("filter_server", %{"host" => host}, socket) do
    {:noreply, patch(socket, %{"server" => host})}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/settings/fediverse/followers")}
  end

  defp flip("asc"), do: "desc"
  defp flip(_desc), do: "asc"

  # The current view with `overrides` applied, as a URL. `page` is dropped
  # unless it is overridden, so any filter or sort change goes back to page 1.
  defp patch(socket, overrides) do
    query = build_query(socket.assigns.filters, overrides)
    push_patch(socket, to: ~p"/settings/fediverse/followers?#{query}")
  end

  # Blanks and defaults are left out, so the default view is a bare
  # /settings/fediverse/followers and a filtered one is a clean, shareable URL.
  defp build_query(filters, overrides \\ %{}) do
    %{
      "q" => filters.q,
      "server" => filters.server,
      "sort" => filters.sort,
      "dir" => filters.dir
    }
    |> Map.merge(overrides)
    |> drop_defaults()
  end

  defp drop_defaults(query) do
    sort = query["sort"] || "followed"

    query
    |> Enum.reject(fn
      {_key, value} when value in [nil, ""] -> true
      {"sort", "followed"} -> true
      {"dir", dir} -> dir == Fediverse.follower_default_dir(sort)
      {"page", "1"} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  # Any narrowing of the full list — what the "Clear" control and the empty
  # state key on. A sort is not a filter: it hides nothing.
  defp filtered?(filters), do: filters.q != nil or filters.server != nil

  # The three columns, with the utilities that place them on a phone. The
  # Server column folds away below `sm`: its content is already the tail of
  # every handle (`@user@server`), and keeping it would push "Following since"
  # off the card edge, so the two facts a phone reader came for - who, and
  # since when - both fit without a sideways scroll. The server *filter* stays
  # reachable through the dropdown at every width.
  @server_column_class "hidden sm:table-cell"

  defp server_column_class, do: @server_column_class

  defp columns do
    [
      {"account", gettext("Account"), nil},
      {"server", gettext("Server"), @server_column_class},
      {"followed", gettext("Following since"), nil}
    ]
  end

  defp sort_caret(filters, column) do
    cond do
      filters.sort != column -> ""
      filters.dir == "asc" -> " ▲"
      true -> " ▼"
    end
  end

  defp aria_sort(%{sort: column, dir: "asc"}, column), do: "ascending"
  defp aria_sort(%{sort: column}, column), do: "descending"
  defp aria_sort(_filters, _column), do: "none"

  # "1-50 of 12,483": the exact figures, because knowing where you are in a
  # long list is the whole point of the line (delimited, not compact).
  defp range_first(page, per_page, total) when total > 0, do: (page - 1) * per_page + 1
  defp range_first(_page, _per_page, _total), do: 0

  defp range_last(page, per_page, total), do: min(page * per_page, total)

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell
      user={@user}
      active={:fediverse}
      title={gettext("Followers from other networks")}
      crumbs={[
        {gettext("Settings"), ~p"/settings"},
        {gettext("Fediverse"), ~p"/settings/fediverse"},
        gettext("Followers")
      ]}
    >
      <div class="space-y-6">
        <.card>
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <.section_title>{gettext("Followers from other networks")}</.section_title>
            <span
              id="follower-total"
              class="rounded-full bg-slate-100 px-2 py-0.5 text-sm font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300"
            >
              {delimited_count(@total_followers)}
            </span>
          </div>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Everyone on another network who follows your vutuv posts. Only you see this list: the followers collection your profile publishes carries the number, never the names."
            )}
          </p>

          <%= if @total_followers == 0 do %>
            <p class="mt-4 text-sm text-slate-600 dark:text-slate-400" id="no-followers">
              {gettext(
                "Nobody yet. Post your handle where people can see it, and the first follows will show up here."
              )}
            </p>
          <% else %>
            <%!-- One form for both controls, so typing and picking a server
            are the same round trip. Debounced, since every keystroke is a
            query over the member's whole follower list. --%>
            <form
              id="follower-filter"
              phx-change="filter"
              phx-submit="filter"
              class="mt-4 flex flex-wrap items-end gap-3"
            >
              <div class="min-w-48 grow">
                <label
                  for="filter-q"
                  class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
                >
                  {gettext("Search")}
                </label>
                <input
                  type="search"
                  name="q"
                  id="filter-q"
                  value={@filters.q}
                  phx-debounce="250"
                  autocomplete="off"
                  placeholder={gettext("name, handle or server")}
                  class={input_class()}
                />
              </div>
              <div :if={@hosts != []}>
                <label
                  for="filter-server"
                  class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
                >
                  {gettext("Server")}
                </label>
                <select name="server" id="filter-server" class={input_class()}>
                  <option value="" selected={is_nil(@filters.server)}>
                    {gettext("All servers")}
                  </option>
                  <%!-- The current filter always shows, even when it is not
                  among the biggest servers offered — otherwise a shared link
                  would render a select that contradicts the list below it. --%>
                  <option
                    :if={@filters.server && @filters.server not in Enum.map(@hosts, & &1.host)}
                    value={@filters.server}
                    selected
                  >
                    {@filters.server}
                  </option>
                  <option
                    :for={host <- @hosts}
                    value={host.host}
                    selected={@filters.server == host.host}
                  >
                    {host.host} ({compact_count(host.followers)})
                  </option>
                </select>
              </div>
              <button
                :if={filtered?(@filters)}
                type="button"
                phx-click="clear"
                id="clear-filters"
                class="py-2 text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
              >
                {gettext("Clear filters")}
              </button>
            </form>

            <p
              :if={@followers == []}
              class="mt-4 text-sm text-slate-600 dark:text-slate-400"
              id="no-matches"
            >
              {gettext("No follower matches that. Try a shorter search, or clear the filters.")}
            </p>

            <div :if={@followers != []} class="card__tablewrap mt-4">
              <table class="pure-table">
                <thead>
                  <tr>
                    <th
                      :for={{col, label, class} <- columns()}
                      aria-sort={aria_sort(@filters, col)}
                      class={class}
                    >
                      <button
                        type="button"
                        phx-click="sort"
                        phx-value-col={col}
                        id={"sort-#{col}"}
                        class="font-semibold text-slate-700 hover:text-brand-700 dark:text-slate-200 dark:hover:text-brand-300"
                      >
                        {label}{sort_caret(@filters, col)}
                      </button>
                    </th>
                  </tr>
                </thead>
                <tbody id="followers">
                  <tr :for={follower <- @followers} id={"follower-#{follower.id}"}>
                    <td>
                      <a
                        href={follower.actor_uri}
                        target="_blank"
                        rel="nofollow noopener noreferrer"
                        class="group block min-w-0"
                      >
                        <%!-- A handle is one long unbreakable token, so on a
                        phone its min-content would set the table's width and
                        push the date column past the card edge. `break-all`
                        below `sm` lets it wrap onto a second line instead;
                        from `sm` up it fits and breaks only at spaces again. --%>
                        <span
                          :if={follower.name}
                          class="breakwrap block font-medium text-slate-800 group-hover:text-brand-700 dark:text-slate-100 dark:group-hover:text-brand-300"
                        >
                          {follower.name}
                        </span>
                        <span class="block break-all text-slate-600 group-hover:text-brand-600 dark:text-slate-400 dark:group-hover:text-brand-300 sm:break-normal">
                          {Follower.display_handle(follower)}
                        </span>
                      </a>
                    </td>
                    <td class={server_column_class()}>
                      <button
                        type="button"
                        phx-click="filter_server"
                        phx-value-host={Follower.host(follower)}
                        title={gettext("Show only followers from this server")}
                        class="text-slate-600 underline decoration-dotted underline-offset-2 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
                      >
                        {Follower.host(follower)}
                      </button>
                    </td>
                    <td class="whitespace-nowrap text-slate-600 dark:text-slate-400">
                      <.local_time
                        at={follower.inserted_at}
                        id={"followed-#{follower.id}"}
                        format="%Y-%m-%d"
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p :if={@followers != []} class="mt-3 text-xs text-slate-600 dark:text-slate-400">
              {gettext("Showing %{first}-%{last} of %{total}.",
                first: delimited_count(range_first(@page, @per_page, @total)),
                last: delimited_count(range_last(@page, @per_page, @total)),
                total: delimited_count(@total)
              )}
            </p>

            <.pager
              params={%{"page" => @page}}
              total={@total}
              per_page={@per_page}
              path={~p"/settings/fediverse/followers"}
              query={build_query(@filters)}
            />
          <% end %>
        </.card>

        <.card>
          <.section_title>{gettext("How this list keeps itself honest")}</.section_title>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Accounts that no longer exist on their own server drop off this list by themselves. Names and handles are the ones their server last told us, so a renamed account updates here on its own too."
            )}
          </p>
          <.card_footer_link href={~p"/settings/fediverse"}>
            {gettext("Back to Fediverse settings")}
          </.card_footer_link>
        </.card>
      </div>
    </.settings_shell>
    """
  end
end
