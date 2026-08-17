defmodule VutuvWeb.VCardController do
  @moduledoc """
  The session-aware vCard download (`/:slug/vcard`), the one the profile's own
  download link points at for a signed-in viewer. The profile's canonical,
  cache-safe vCard lives at `/:slug.vcf` (see `VutuvWeb.AgentDocs`) and always
  renders the anonymous public view.

  This route exists because a vCard is the one export whose whole purpose is the
  contact details, and those are audience-scoped (issue #1521): whoever downloads
  it gets exactly the email addresses and phone numbers the ladder grants **them**
  — a stranger the public ones, a signed-in member anything opened to members, a
  vernetzt contact the numbers kept for connections, and the owner everything
  including their private rows. That is the answer to "if you grant me access to
  your phone number, I want to be able to download the correct vCard with that
  information": the file follows the page.

  Because the body therefore differs per viewer, the response is explicitly
  **uncacheable**. Without that, a shared cache (nginx sits in front of the app in
  production) could hand one member's download to the next person to ask for the
  same URL, which would defeat the whole ladder in one header.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.AgentDocs.VCard

  def get(conn, _params) do
    user = conn.assigns[:user]

    # `:viewer` is all it takes — ProfileDoc resolves both contact channels
    # through Vutuv.Accounts.contact_scope/2, so this route cannot drift from
    # what the profile page shows the same person.
    doc = ProfileDoc.build(user, include_photo: true, viewer: conn.assigns[:current_user])

    # Plain text/vcard, sent directly: Phoenix format/view resolution only
    # knows :html and :json and cannot resolve a "vcf" view.
    conn
    |> put_resp_content_type("text/vcard")
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("vary", "cookie")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"#{VCard.filename(doc)}\""
    )
    |> send_resp(200, VCard.render(doc))
  end
end
