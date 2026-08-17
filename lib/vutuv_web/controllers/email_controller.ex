defmodule VutuvWeb.EmailController do
  use VutuvWeb, :controller
  alias Vutuv.AccountEvents
  alias Vutuv.Accounts
  alias Vutuv.Accounts.Email
  alias Vutuv.Notifications.Emailer
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.RateLimit

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "email" when action in [:create, :update])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs.
  def index(conn, _params) do
    AgentDocs.respond(conn,
      html: fn conn ->
        # The showcase view: whatever rung this viewer stands on (issue #1521),
        # minus "private" — a private address shows solely on /settings/emails,
        # for the owner too. See UserHelpers.showcase_scope/2.
        emails =
          VutuvWeb.UserHelpers.emails_for_scope(
            conn.assigns[:user],
            VutuvWeb.UserHelpers.showcase_scope(conn.assigns[:user], conn.assigns[:current_user])
          )

        render(conn, "index.html",
          emails: emails,
          as_owner?: false,
          page_title:
            VutuvWeb.UserHelpers.member_page_title(
              conn.assigns[:user],
              gettext("Email addresses")
            )
        )
      end,
      doc: fn ->
        emails = VutuvWeb.UserHelpers.emails_for_display(conn.assigns[:user], nil)
        SectionDocs.build_index(conn.assigns[:user], :emails, emails)
      end
    )
  end

  # The owner's editor (GET /settings/emails): every address on every rung of
  # the ladder, with the add tile, reorder tool and per-row actions.
  def manage(conn, _params) do
    emails =
      VutuvWeb.UserHelpers.emails_for_scope(conn.assigns[:user], Vutuv.Visibility.levels())

    render(conn, "manage.html",
      emails: emails,
      as_owner?: true,
      page_title: gettext("Email addresses")
    )
  end

  def new(conn, _params) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:emails)
      |> Email.changeset()

    render(conn, "new.html", changeset: changeset)
  end

  # Step 1: mail a PIN for the new address and render the PIN-entry form. The new
  # address rides along in the login_pin's `payload` column until it is confirmed.
  #
  # The address format is validated up front (the same Email.changeset that
  # step 2 inserts through) so a malformed address is rejected here instead of
  # after the member has chased down and entered a PIN we mailed to a bogus
  # address — and so we never mail a PIN to something that isn't an address.
  def create(conn, %{"email" => email_params}) do
    user = conn.assigns[:current_user]
    email = email_params["value"]

    changeset =
      user
      |> build_assoc(:emails)
      |> Email.changeset(email_params)

    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- RateLimit.check(conn, :email_change, email) do
      user
      |> Accounts.gen_pin_for("email", email)
      |> Emailer.email_creation_email(email, user)
      |> Emailer.deliver()

      conn
      # The login_pin payload is a single string already carrying the new
      # address, so the chosen Work/Personal/Other label waits in the
      # session until step 2's PIN confirms the address.
      |> put_session(:pending_email_type, email_params["email_type"])
      |> render("confirm.html", user: conn.assigns[:user])
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/settings/emails")
    end
  end

  # Step 2: the PIN confirms the new address, which is then inserted.
  def confirm(conn, %{"email_confirmation" => %{"pin" => pin}}) do
    case RateLimit.check(conn, :email_pin) do
      :ok ->
        verify_email_pin(conn, pin)

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/settings/emails")
    end
  end

  defp verify_email_pin(conn, pin) do
    case Accounts.check_pin(conn.assigns[:current_user], pin, "email") do
      {:ok, new_email, user} ->
        email_type = get_session(conn, :pending_email_type) || "Other"

        user
        # Append to the owner's chosen order (position set on the struct, never
        # cast); reordering lives in VutuvWeb.SectionReorderLive.
        |> build_assoc(:emails, position: Vutuv.Ordering.next_position(Email, user.id))
        |> Email.changeset(%{value: new_email, email_type: email_type})
        |> Repo.insert()
        |> case do
          {:ok, email} ->
            # A new address is a new way to receive a login PIN, so it belongs
            # in the activity log (issue #1087) — but MASKED: the owner
            # recognizes "an***@example.com" at a glance, while a leaked backup
            # or the admin's cross-member view gains no working address.
            AccountEvents.record(user, "email_added",
              conn: conn,
              factor: "pin",
              details: %{email: AccountEvents.mask_email(email.value)}
            )

            conn
            |> delete_session(:pending_email_type)
            |> put_flash(:info, gettext("Email created successfully."))
            |> redirect(to: ~p"/")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, gettext("That email could not be added."))
            |> redirect(to: ~p"/settings/emails")
        end

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> render("confirm.html", user: conn.assigns[:user])

      {:already_used, message} ->
        conn
        |> put_flash(:info, message)
        |> redirect(to: ~p"/settings/emails")

      {:expired, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/settings/emails")

      :lockout ->
        conn
        |> put_flash(:error, gettext("Too many incorrect attempts."))
        |> redirect(to: ~p"/settings/emails")
    end
  end

  def show(conn, %{"id" => id}) do
    case AgentDocs.negotiate(conn) do
      :html -> show_html(conn, id)
      format -> show_doc(conn, format, id)
    end
  end

  defp show_html(conn, id) do
    email =
      if VutuvWeb.UserHelpers.user_has_permissions?(
           conn.assigns[:user],
           conn.assigns[:current_user]
         ) do
        ControllerHelpers.get_owned(conn.assigns[:user], :emails, id)
      else
        scoped_email(
          conn,
          id,
          VutuvWeb.UserHelpers.showcase_scope(conn.assigns[:user], conn.assigns[:current_user])
        )
      end

    case email do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      email ->
        conn
        |> maybe_put_alternates(email)
        |> render("show.html",
          email: email,
          page_title:
            VutuvWeb.UserHelpers.member_page_title(
              conn.assigns[:user],
              gettext("Email addresses")
            )
        )
    end
  end

  # Advertise the agent-format siblings only for an "everyone" address: those
  # URLs are cached and crawlable, so anything narrower 404s there whoever asks.
  defp maybe_put_alternates(conn, email) do
    if Email.visibility_of(email) == "everyone",
      do: AgentDocs.put_html_alternates(conn),
      else: conn
  end

  # The single-address agent documents stay strictly the anonymous view: they are
  # publicly cacheable URLs, so an address opened up to members or connections
  # has no .md/.txt/.json sibling even for a viewer who may see it on the page.
  # The viewer-scoped download is the profile's vCard.
  defp show_doc(conn, format, id) do
    case scoped_email(conn, id, ["everyone"]) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      email ->
        doc = SectionDocs.build_show(conn.assigns[:user], :emails, email)
        AgentDocs.send_doc(conn, format, doc)
    end
  end

  # One address, but only if it sits on a rung in `scope` — the single-entry twin
  # of UserHelpers.emails_for_scope/2, carrying the same legacy `public?`
  # fallback for a row the previous release wrote (issue #1521).
  defp scoped_email(conn, id, scope) do
    Vutuv.UUIDv7.with_cast(id, fn uuid ->
      Repo.one(
        from(e in assoc(conn.assigns[:user], :emails),
          where:
            e.id == ^uuid and
              fragment(
                "coalesce(?, CASE WHEN ? THEN 'everyone' ELSE 'private' END)",
                e.visibility,
                e.public?
              ) in ^scope
        )
      )
    end)
  end

  # Editing is limited to the public? flag: changing the address itself would
  # bypass the PIN verification above, so a new address means create + delete.
  def edit(conn, %{"id" => id}) do
    email = ControllerHelpers.get_owned!(conn, :emails, id)
    changeset = Email.update_changeset(email)
    render(conn, "edit.html", email: email, changeset: changeset)
  end

  def update(conn, %{"id" => id, "email" => email_params}) do
    email = ControllerHelpers.get_owned!(conn, :emails, id)
    changeset = Email.update_changeset(email, email_params)
    result = Repo.update(changeset)

    case result do
      {:ok, updated} ->
        # Who can see an address is a privacy decision, so the log records the
        # new rung — with the address itself masked, as always. Events stored
        # before issue #1521 carry a `public` boolean instead; the renderer
        # (`VutuvWeb.AccountEventText`) reads both.
        AccountEvents.record(conn.assigns.current_user, "email_updated",
          conn: conn,
          details: %{
            email: AccountEvents.mask_email(updated.value),
            visibility: Email.visibility_of(updated)
          }
        )

      _error ->
        :ok
    end

    ControllerHelpers.save(conn, result,
      flash: gettext("Email updated successfully."),
      redirect_to: ~p"/settings/emails",
      render: "edit.html",
      assigns: [email: email]
    )
  end

  def delete(conn, %{"id" => id}) do
    email = ControllerHelpers.get_owned!(conn, :emails, id)

    if Email.can_delete?(conn.assigns.current_user.id) do
      # Here we use delete! (with a bang) because we expect
      # it to always work (and if it does not, it will raise).
      Repo.delete!(email)

      AccountEvents.record(conn.assigns.current_user, "email_removed",
        conn: conn,
        details: %{email: AccountEvents.mask_email(email.value)}
      )

      conn
      |> put_flash(:info, gettext("Email deleted successfully."))
      |> redirect(to: ~p"/settings/emails")
    else
      conn
      |> put_flash(:error, gettext("Cannot delete final email."))
      |> redirect(to: ~p"/settings/emails")
    end
  end
end
