defmodule VutuvWeb.AddressController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.Address
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Plug.Locale

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs).
  #
  # The two halves answer to different audiences on purpose (issue #1521), the
  # same split the phone-number and email controllers carry: the HTML page shows
  # the rung this viewer stands on minus "private", while the agent documents stay
  # strictly the anonymous view because those URLs are publicly cacheable and
  # crawlable. A viewer who may see more gets it from the page and from the
  # session-aware vCard.
  def index(conn, _params) do
    user = conn.assigns[:user]

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          addresses: showcase_addresses(conn),
          page_title: VutuvWeb.UserHelpers.member_page_title(user, gettext("Addresses"))
        )
      end,
      doc: fn ->
        SectionDocs.build_index(
          user,
          :addresses,
          VutuvWeb.UserHelpers.addresses_for_scope(user, ["everyone"])
        )
      end
    )
  end

  # The addresses the HTML showcase page lists for whoever is asking.
  defp showcase_addresses(conn) do
    VutuvWeb.UserHelpers.addresses_for_scope(
      conn.assigns[:user],
      VutuvWeb.UserHelpers.showcase_scope(conn.assigns[:user], conn.assigns[:current_user])
    )
  end

  # The owner's editor (GET /settings/addresses): every rung.
  def manage(conn, _params) do
    user = user_with_addresses(conn)

    render(conn, "manage.html",
      user: user,
      addresses: user.addresses,
      as_owner?: true,
      page_title: gettext("Addresses")
    )
  end

  def new(conn, _params) do
    changeset = Address.changeset(%Address{}, %{})
    render(conn, "new.html", country: get_template(conn), changeset: changeset)
  end

  def create(conn, %{"address" => address_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      # New entries append to the owner's chosen order (position set on the
      # struct, never cast); reordering lives in VutuvWeb.SectionReorderLive.
      |> build_assoc(:addresses, position: Vutuv.Ordering.next_position(Address, user.id))
      |> Address.changeset(address_params)

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Address created successfully."),
      redirect_to: ~p"/settings/addresses",
      render: "new.html",
      assigns: [country: get_template(conn)]
    )
  end

  def create(conn, %{"country_select" => country_param}) do
    changeset = Address.changeset(%Address{}, country_param)
    render(conn, "new.html", changeset: changeset, country: get_template(conn))
  end

  # `get_owned!/3` scopes to the **profile owner**, not to the viewer, so this page
  # used to hand any address to anybody — right while every address was public, a
  # leak now. A viewer who may not see this address gets a 404, exactly like an
  # address that does not exist: a "you are not allowed to see this" page would
  # confirm that the member has one on file. The doc half serves the anonymous
  # view only (see `index/2`).
  def show(conn, %{"id" => id}) do
    case AgentDocs.negotiate(conn) do
      :html ->
        scope =
          VutuvWeb.UserHelpers.showcase_scope(conn.assigns[:user], conn.assigns[:current_user])

        show_html(conn, id, scope)

      format ->
        show_doc(conn, format, id)
    end
  end

  defp show_html(conn, id, scope) do
    user = conn.assigns[:user]

    case scoped_address(user, id, scope) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      address ->
        conn
        |> maybe_put_alternates(address)
        |> render("show.html", address: address, page_title: entry_page_title(user, address))
    end
  end

  defp show_doc(conn, format, id) do
    user = conn.assigns[:user]

    case scoped_address(user, id, ["everyone"]) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      address ->
        AgentDocs.send_doc(conn, format, SectionDocs.build_show(user, :addresses, address))
    end
  end

  # One address, but only if it sits on a rung in `scope`.
  defp scoped_address(user, id, scope) do
    case ControllerHelpers.get_owned(user, :addresses, id) do
      nil -> nil
      address -> if Address.visibility_of(address) in scope, do: address
    end
  end

  # Advertise the agent-format siblings only for an "everyone" address: anything
  # narrower has no document, so linking one would advertise a 404.
  defp maybe_put_alternates(conn, address) do
    if Address.visibility_of(address) == "everyone",
      do: AgentDocs.put_html_alternates(conn),
      else: conn
  end

  defp entry_page_title(user, address) do
    label =
      if address.description in [nil, ""], do: gettext("Addresses"), else: address.description

    VutuvWeb.UserHelpers.member_page_title(user, label)
  end

  def edit(conn, %{"id" => id}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)
    changeset = Address.changeset(address)
    render(conn, "edit.html", address: address, changeset: changeset, country: get_template(conn))
  end

  def update(conn, %{"id" => id, "address" => address_params}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)
    changeset = Address.changeset(address, address_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Address updated successfully."),
      redirect_to: ~p"/settings/addresses",
      render: "edit.html",
      assigns: [address: address, country: get_template(conn)]
    )
  end

  def delete(conn, %{"id" => id}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)

    ControllerHelpers.delete(conn, address,
      flash: gettext("Address deleted successfully."),
      redirect_to: ~p"/settings/addresses"
    )
  end

  defp get_template(conn) do
    loc =
      conn
      |> VutuvWeb.UserHelpers.locale(conn.assigns[:user])

    if Locale.locale_supported?(loc), do: loc, else: "generic"
  end

  defp user_with_addresses(conn),
    do: Repo.preload(conn.assigns[:user], addresses: Address.ordered())
end
