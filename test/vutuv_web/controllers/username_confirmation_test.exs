defmodule VutuvWeb.UsernameConfirmationTest do
  use VutuvWeb.ConnCase, async: false

  @moduledoc """
  Issue #1086: a rename is re-confirmed before it happens.

  Until this shipped, a live session was the only thing between a borrowed
  laptop and a public-identity change that frees the old handle for anyone to
  claim — while adding an email and deleting the account, its neighbours on the
  settings menu, both ask for a PIN. Step 1 now only validates and remembers the
  new handle; step 2 takes a passkey, an authenticator/list code, or a PIN
  emailed to one of the member's **own** addresses.

  `async: false`: the PIN attempt counters and the rate limiter are process- and
  ETS-backed state the SQL sandbox does not roll back.
  """

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.Accounts.{LoginPin, User}
  alias Vutuv.LoginCodes

  # Step 1 of a rename, from a logged-in conn. Returns the conn showing the
  # confirmation page.
  defp start_rename(conn, handle \\ "brand_new") do
    post(conn, ~p"/settings/username", user: %{"username" => handle})
  end

  defp totp_user(user) do
    {:ok, pending} = LoginCodes.start_totp_enrollment(user)
    {:ok, _} = LoginCodes.confirm_totp(user, NimbleTOTP.verification_code(pending.secret))

    # The confirm stamped the current 30s window as used; backdate it so a fresh
    # code works without waiting a real window out.
    LoginCodes.get_totp(user)
    |> Ecto.Changeset.change(last_used_at: DateTime.add(DateTime.utc_now(:second), -120))
    |> Repo.update!()

    pending.secret
  end

  describe "step 1 no longer renames" do
    test "a valid handle advances to the confirmation instead of committing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      old_handle = user.username

      conn = start_rename(conn)

      html = html_response(conn, 200)
      # The page states plainly what is about to happen, both handles visible.
      assert html =~ "@brand_new"
      assert html =~ "@#{old_handle}"
      assert html =~ "_csrf_token"

      # Nothing has changed yet, and the old address still works.
      assert Repo.get(User, user.id).username == old_handle
    end

    test "an invalid handle never reaches the confirmation and mails nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      flush_emails()

      conn = start_rename(conn, "not valid!")

      assert html_response(conn, 422) =~ "may only contain letters, numbers, and underscores"
      assert Repo.get(User, user.id).username == user.username
      # The whole point of validating first: no PIN chase for a name that was
      # never going to be accepted.
      refute_received {:email, _}
    end

    test "a handle taken by someone else is refused before any PIN goes out", %{conn: conn} do
      insert(:user, username: "wanted_handle")
      {conn, _user} = create_and_login_user(conn)
      flush_emails()

      conn = start_rename(conn, "wanted_handle")

      assert html_response(conn, 422) =~ "has already been taken"
      refute_received {:email, _}
    end
  end

  describe "the email PIN (the floor everybody has)" do
    test "one address and no other factor: the PIN is already on its way", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      email = Accounts.first_email_value(user)
      flush_emails()

      conn = start_rename(conn)
      html = html_response(conn, 200)

      # No choice to make, so the page just says where to look.
      assert html =~ email
      pin = sent_pin()

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "@brand_new"
    end

    test "the PIN names the handle it authorizes", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      flush_emails()

      start_rename(conn, "renamed_soon")

      assert_received {:email, email}
      assert email.subject =~ "username"
      assert email.text_body =~ "@renamed_soon"
      # An unasked-for PIN has to read as an alarm, not as noise.
      assert email.text_body =~ "did not ask"
    end

    test "a wrong PIN keeps the pending change so the member can retry", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      pin = sent_pin()
      wrong = if pin == "000000", do: "000001", else: "000000"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => wrong}
        })

      assert redirected_to(conn) == ~p"/settings/username/confirm"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Incorrect"
      assert Repo.get(User, user.id).username == user.username

      # The pending handle survived, so the right PIN still finishes the job.
      conn = conn |> recycle() |> get(~p"/settings/username/confirm")
      assert html_response(conn, 200) =~ "@brand_new"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(conn) == ~p"/brand_new"
    end

    test "a spent PIN cannot be replayed into a second rename", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      pin = sent_pin()

      first =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(first) == ~p"/brand_new"

      # Re-submitting the consumed PIN (a double-tap, a back-navigation) must not
      # rename anything again; the pending change went with the first success.
      second =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(second) == ~p"/settings/username"
      assert Repo.get(User, user.id).username == "brand_new"
    end
  end

  describe "choosing which address gets the PIN" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:email,
        value: "second-#{System.unique_integer([:positive])}@example.com",
        user: user
      )

      flush_emails()

      %{conn: conn, user: user}
    end

    test "with several addresses nothing is mailed until one is picked", %{
      conn: conn,
      user: user
    } do
      conn = start_rename(conn)
      html = html_response(conn, 200)

      # Every address the member owns is offered, and none of them was mailed
      # behind their back.
      for value <- Accounts.list_email_values(user), do: assert(html =~ value)
      assert html =~ "username_pin[email]"
      refute_received {:email, _}
    end

    test "the page never claims a PIN was mailed when none was", %{conn: conn} do
      # Caught in the browser: the code field's hint read "enter the PIN we
      # emailed you" on a page that had deliberately mailed nothing, which sends
      # the member hunting through an inbox for a mail that does not exist.
      html = conn |> start_rename() |> html_response(200)

      refute html =~ "We sent a PIN"
      assert html =~ "Ask for a PIN first"
      # And the way to get one is above the field, not stranded under the submit.
      assert html =~ ~r/username-pin-form.*username-confirm-form/s
    end

    test "the PIN goes to the address the member picked", %{conn: conn, user: user} do
      [_first, second] = Accounts.list_email_values(user)
      conn = start_rename(conn)

      conn =
        submit_with_csrf(conn, ~p"/settings/username/pin", %{
          "username_pin" => %{"email" => second}
        })

      assert redirected_to(conn) == ~p"/settings/username/confirm"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ second

      assert_received {:email, mail}
      assert {_name, ^second} = mail.to |> List.first()
    end

    test "an address the member does not own is refused, and mails nobody", %{conn: conn} do
      conn = start_rename(conn)

      conn =
        submit_with_csrf(conn, ~p"/settings/username/pin", %{
          "username_pin" => %{"email" => "attacker@example.com"}
        })

      assert redirected_to(conn) == ~p"/settings/username/confirm"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "your own email"
      # The real bug this guards: the picker must not be a relay that mails a
      # valid PIN to an address chosen by whoever holds the session.
      refute_received {:email, _}
    end

    test "the PIN mailed to the second address confirms the rename", %{conn: conn, user: user} do
      [_first, second] = Accounts.list_email_values(user)
      conn = start_rename(conn)

      conn =
        submit_with_csrf(conn, ~p"/settings/username/pin", %{
          "username_pin" => %{"email" => second}
        })

      pin = sent_pin()
      conn = conn |> recycle() |> get(~p"/settings/username/confirm")

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
    end
  end

  describe "authenticator app and one-time codes" do
    test "a member with an authenticator app is not mailed a PIN unasked", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      secret = totp_user(user)
      flush_emails()

      conn = start_rename(conn)
      html = html_response(conn, 200)

      # They have a faster way in, so mailing anyway would train them to ignore
      # exactly the mail that is meant to alarm them.
      refute_received {:email, _}
      assert html =~ "authenticator app"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
    end

    test "a one-time list code confirms the rename too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      [code | _] = LoginCodes.generate_list_codes(user)
      flush_emails()

      conn = start_rename(conn)
      refute_received {:email, _}

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => code.code}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
    end

    test "an alternate code spends a PIN that was mailed alongside it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      secret = totp_user(user)
      conn = start_rename(conn)

      # The member asked for a PIN as well, then used their app instead. The PIN
      # left in the inbox must not stay live.
      conn =
        submit_with_csrf(conn, ~p"/settings/username/pin", %{
          "username_pin" => %{"email" => Accounts.first_email_value(user)}
        })

      _pin = sent_pin()
      conn = conn |> recycle() |> get(~p"/settings/username/confirm")

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert redirected_to(conn) == ~p"/brand_new"

      row = Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == "username"))
      assert row.consumed_at
    end
  end

  describe "passkey confirmation" do
    test "the button is offered only to members who enrolled one", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = start_rename(conn)
      refute html_response(conn, 200) =~ "data-webauthn-confirm"

      insert(:user_credential, user: user)
      conn = conn |> recycle() |> get(~p"/settings/username/confirm")
      html = html_response(conn, 200)

      assert html =~ "data-webauthn-confirm"
      assert html =~ ~s(data-challenge-url="#{~p"/settings/username/passkey/challenge"}")
      # Verifying stamps the session; the JS then submits the ordinary form, so
      # the rename keeps one CSRF-protected commit path.
      assert html =~ ~s(data-submit-form="username-passkey-form")
    end

    test "the challenge endpoint answers JSON and stores the challenge", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      conn = start_rename(conn)

      conn = conn |> recycle() |> post(~p"/settings/username/passkey/challenge")

      assert %{"rpId" => "localhost"} = json_response(conn, 200)
      assert %Wax.Challenge{} = get_session(conn, :username_change_challenge)
    end

    test "a bogus assertion renames nobody", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      conn = conn |> recycle() |> post(~p"/settings/username/passkey/challenge")

      conn =
        conn
        |> recycle()
        |> post(~p"/settings/username/passkey", %{
          "rawId" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
          "authenticatorData" => Base.url_encode64("authdata", padding: false),
          "signature" => Base.url_encode64("signature", padding: false),
          "clientDataJSON" => Base.url_encode64("{}", padding: false)
        })

      assert %{"ok" => false} = json_response(conn, 422)
      refute get_session(conn, :username_change_passkey_at)
      assert Repo.get(User, user.id).username == user.username
    end

    test "a completed ceremony confirms without any code", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)

      # Stand in for the browser ceremony (it cannot run in the test adapter):
      # this is the session stamp passkey_verify/2 leaves behind on success.
      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          username_change: "brand_new",
          username_change_at: System.system_time(:second),
          username_change_passkey_at: System.system_time(:second)
        })

      conn =
        conn
        |> put_private(:plug_skip_csrf_protection, true)
        |> post(~p"/settings/username/confirm", %{})

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
      # One rename per ceremony: the stamp is spent with the change.
      refute get_session(conn, :username_change_passkey_at)
    end

    test "a stale ceremony no longer confirms", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          username_change: "brand_new",
          username_change_at: System.system_time(:second),
          # Older than the 10-minute window: whoever sits down at the abandoned
          # laptop must not be able to finish it.
          username_change_passkey_at: System.system_time(:second) - 3_600
        })

      conn =
        conn
        |> put_private(:plug_skip_csrf_protection, true)
        |> post(~p"/settings/username/confirm", %{})

      assert redirected_to(conn) == ~p"/settings/username/confirm"
      assert Repo.get(User, user.id).username == user.username
    end
  end

  describe "German" do
    test "the confirmation page is German for a German visitor", %{conn: conn} do
      # vutuv is a German site, so an untranslated new page is an English island
      # in the middle of the settings area — and a plain English test never sees
      # it. Assert the German render of the strings this page introduced.
      {conn, _user} = create_and_login_user(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> post(~p"/settings/username", user: %{"username" => "neuer_name"})
        |> html_response(200)

      assert html =~ "Was sich ändert"
      assert html =~ "Bestätigen Sie, dass Sie es sind"
      assert html =~ "Benutzernamen jetzt ändern"
      refute html =~ "What will change"
    end

    test "the PIN email is German for a German member", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(locale: "de") |> Repo.update!()
      flush_emails()

      start_rename(conn)

      assert_received {:email, mail}
      assert mail.subject =~ "Benutzernamen"
      assert mail.text_body =~ "Der PIN verfällt"
    end
  end

  describe "a confirmation with nothing pending" do
    test "the page sends the member back to the form", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      assert conn |> get(~p"/settings/username/confirm") |> redirected_to() ==
               ~p"/settings/username"
    end

    test "submitting a code renames nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/settings/username")

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => "123456"}
        })

      assert redirected_to(conn) == ~p"/settings/username"
      assert Repo.get(User, user.id).username == user.username
    end

    test "going back to the form does not destroy the confirmation", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      pin = sent_pin()

      # A GET must be safe. This URL is reached by accident constantly — the
      # sidebar row, the breadcrumb, the Back button, a link prefetch — and
      # clearing the pending rename here made any of those answer the member's
      # correct PIN with "this confirmation expired" (found in a browser smoke
      # test, with nothing on screen to explain it).
      conn = conn |> recycle() |> get(~p"/settings/username")
      assert html_response(conn, 200) =~ ~s(id="slug-form")

      conn = conn |> recycle() |> get(~p"/settings/username/confirm")
      assert html_response(conn, 200) =~ "@brand_new"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
    end

    test "a confirmation left for half an hour goes stale", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      pin = sent_pin()

      # Keeping the pending change across GETs must not mean keeping it forever:
      # it ages out with the PIN that confirms it.
      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          username_change: "brand_new",
          username_change_at: System.system_time(:second) - 3_600
        })

      conn =
        conn
        |> put_private(:plug_skip_csrf_protection, true)
        |> post(~p"/settings/username/confirm", %{"username_confirmation" => %{"code" => pin}})

      assert redirected_to(conn) == ~p"/settings/username"
      assert Repo.get(User, user.id).username == user.username
    end

    test "guests cannot reach any step of the confirmation", %{conn: conn} do
      assert conn |> get(~p"/settings/username/confirm") |> redirected_to() == "/"
      assert conn |> post(~p"/settings/username/confirm") |> redirected_to() == "/"
      assert conn |> post(~p"/settings/username/pin") |> redirected_to() == "/"
      assert conn |> post(~p"/settings/username/passkey/challenge") |> redirected_to() == "/"
    end
  end
end
