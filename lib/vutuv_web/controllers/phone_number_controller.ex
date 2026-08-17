defmodule VutuvWeb.PhoneNumberController do
  use VutuvWeb, :controller
  alias Vutuv.Profiles.PhoneNumber
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "phone_number" when action in [:create, :update])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs).
  #
  # The two halves resolve **different** audiences on purpose (issue #1521). The
  # HTML page shows the rung this viewer stands on, minus "private" — the same
  # showcase rule the email section page follows. The agent documents stay
  # strictly the anonymous view, because those URLs are publicly cacheable and
  # crawlable: serving one viewer's wider answer there would put a number that
  # was opened up to connections into a shared cache. A viewer who may see more
  # gets it from the page, and as a download from the session-aware vCard.
  def index(conn, _params) do
    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          phone_numbers: showcase_numbers(conn),
          page_title:
            VutuvWeb.UserHelpers.member_page_title(conn.assigns[:user], gettext("Phone numbers"))
        )
      end,
      doc: fn ->
        numbers =
          VutuvWeb.UserHelpers.phone_numbers_for_scope(conn.assigns[:user], ["everyone"])

        SectionDocs.build_index(conn.assigns[:user], :phone_numbers, numbers)
      end
    )
  end

  # The numbers the HTML showcase page lists for whoever is asking.
  defp showcase_numbers(conn) do
    VutuvWeb.UserHelpers.phone_numbers_for_scope(
      conn.assigns[:user],
      VutuvWeb.UserHelpers.showcase_scope(conn.assigns[:user], conn.assigns[:current_user])
    )
  end

  # The owner's editor (GET /settings/phone_numbers).
  def manage(conn, _params) do
    phone_numbers = Repo.all(PhoneNumber.ordered(assoc(conn.assigns[:user], :phone_numbers)))

    render(conn, "manage.html",
      phone_numbers: phone_numbers,
      as_owner?: true,
      page_title: gettext("Phone numbers")
    )
  end

  def new(conn, _params) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:phone_numbers)
      |> PhoneNumber.changeset()

    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"phone_number" => phone_number_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      # New entries append to the owner's chosen order. `position` is set on the
      # struct (not cast) so a forged param can't move it; reordering lives in
      # VutuvWeb.SectionReorderLive via Vutuv.Ordering.
      |> build_assoc(:phone_numbers, position: Vutuv.Ordering.next_position(PhoneNumber, user.id))
      |> PhoneNumber.changeset(phone_number_params)

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Phone number created successfully."),
      redirect_to: ~p"/settings/phone_numbers",
      render: "new.html"
    )
  end

  # `get_owned!/3` scopes to the **profile owner**, not to the viewer, so before
  # the ladder existed this page handed any number to anybody — which was right
  # while every number was public and is a leak now. The audience is therefore
  # checked here, and a number this viewer may not see 404s exactly like a number
  # that does not exist: a "you are not allowed to see this" page would confirm
  # that the member has a number of that kind on file.
  #
  # The HTML and doc halves are split by hand (rather than through
  # `AgentDocs.respond/2`) because they answer to different audiences — see the
  # note on `index/2`. `.md`/`.txt`/`.json` serve the anonymous view only.
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

    case scoped_number(user, id, scope) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      phone_number ->
        conn
        |> maybe_put_alternates(phone_number)
        |> render("show.html",
          phone_number: phone_number,
          page_title:
            VutuvWeb.UserHelpers.member_page_title(user, phone_number_label(phone_number))
        )
    end
  end

  # Advertise the agent-format siblings only for an "everyone" number: anything
  # narrower has no document, so linking one would advertise a 404.
  defp maybe_put_alternates(conn, phone_number) do
    if PhoneNumber.visibility_of(phone_number) == "everyone",
      do: AgentDocs.put_html_alternates(conn),
      else: conn
  end

  defp show_doc(conn, format, id) do
    user = conn.assigns[:user]

    case scoped_number(user, id, ["everyone"]) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      phone_number ->
        doc = SectionDocs.build_show(user, :phone_numbers, phone_number)
        AgentDocs.send_doc(conn, format, doc)
    end
  end

  # One number, but only if it sits on a rung in `scope`.
  defp scoped_number(user, id, scope) do
    case ControllerHelpers.get_owned(user, :phone_numbers, id) do
      nil -> nil
      number -> if PhoneNumber.visibility_of(number) in scope, do: number
    end
  end

  defp phone_number_label(phone_number) do
    case phone_number.number_type do
      type when type in [nil, ""] -> gettext("Phone numbers")
      type -> "#{gettext("Phone numbers")} · #{type}"
    end
  end

  def edit(conn, %{"id" => id}) do
    phone_number = ControllerHelpers.get_owned!(conn, :phone_numbers, id)
    changeset = PhoneNumber.changeset(phone_number)
    render(conn, "edit.html", phone_number: phone_number, changeset: changeset)
  end

  def update(conn, %{"id" => id, "phone_number" => phone_number_params}) do
    phone_number = ControllerHelpers.get_owned!(conn, :phone_numbers, id)
    changeset = PhoneNumber.changeset(phone_number, phone_number_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Phone number updated successfully."),
      redirect_to: ~p"/settings/phone_numbers",
      render: "edit.html",
      assigns: [phone_number: phone_number]
    )
  end

  def delete(conn, %{"id" => id}) do
    phone_number = ControllerHelpers.get_owned!(conn, :phone_numbers, id)

    ControllerHelpers.delete(conn, phone_number,
      flash: gettext("Phone number deleted successfully."),
      redirect_to: ~p"/settings/phone_numbers"
    )
  end
end
