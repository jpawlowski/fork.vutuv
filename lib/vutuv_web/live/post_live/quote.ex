defmodule VutuvWeb.PostLive.Quote do
  @moduledoc """
  Quote page (issue #1610) — the post being quoted (read-only preview) above the
  same composer the reply page uses. What gets published is a **top-level post
  of the member's own** carrying that post as a compact card, not a reply: it
  opens no thread and moves no reply count.

  The gate is the reshare's rather than the reply's, because the act is the
  reshare's: only a visible, **public**, `Vutuv.Posts.answerable?/1` post can be
  quoted, and everything else is sent away with the unknown-id flash, so
  existence never leaks. A post published in a page's name is quotable like any
  other as long as the page itself is publicly visible, which is what
  `answerable?/1` — shared with `create_quote/3`'s own gate — asks (it is the
  same question for both: is this post in a state that lets somebody else carry
  it).

  A block is deliberately *not* part of the gate, exactly as on the reply page:
  quiet blocking has to let the blocked member reach the composer and be refused
  on submit, or the block leaks.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  alias Vutuv.Posts
  alias VutuvWeb.Live.InitAssigns

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    quoted = Posts.get_post(id)

    # `carryable_by?/2` is the compose page's half of the submit gate, shared
    # with the reply page so a fourth arm cannot land on one and miss the other.
    if quoted && Posts.carryable_by?(quoted, user) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Quote a post"))
       |> assign(:quoted, quoted)}
    else
      {:ok, InitAssigns.not_found(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="post-quote" class="py-6">
      <div class="mx-auto max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
          {gettext("Quote %{handle}", handle: author_handle(Posts.author(@quoted)))}
        </h1>

        <p class="text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Your post carries this one inside it. It is not an answer: it starts no conversation under the post you quote."
          )}
        </p>

        <%!-- quotable={false}: the card's own Reply link would lead away from
        the page being composed on, throwing away whatever has been typed. --%>
        <.post_card
          post={@quoted}
          viewer={@current_user}
          mode={:preview}
          conn_or_socket={@socket}
          quotable={false}
        />

        <.live_component
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={nil}
          parent={nil}
          quoted={@quoted}
        />

        <.link
          href={Posts.path(@quoted)}
          class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Back to the post")}
        </.link>
      </div>
    </div>
    """
  end
end
