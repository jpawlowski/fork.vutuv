// Where each tab was left, across a live navigation (issue #1731).
//
// Two jobs, and the first one is not a nicety. A live navigation does NOT
// touch the scroll position: LiveView replaces the main element and pushes a
// history entry, and nothing in it calls `scrollTo` on the way forward (only a
// back/forward pop restores the entry's own offset). So a reader a screen down
// the feed who presses Messages arrives a screen down the messages page, which
// on a short page means arriving at its footer. Before this file the bottom
// tabs were plain links and the browser did the resetting; now that a press
// patches, that reset is ours to do.
//
// The second is what the reset would otherwise cost: on a phone the tab bar is
// how you leave a page and come back to it, and every native app puts you back
// where you were. So each path's offset is remembered as it is left and put
// back when it is returned to — the difference between glancing at a message
// and losing your place in the feed.
//
// The offset is read at CLICK time, not when the navigation lands. By then the
// new page's markup is already in the document and a shorter page has clamped
// `scrollY` to something that was never where the reader was. Reading it from
// the press also means this file listens for no `scroll` events at all, so
// nothing here depends on how a browser coalesces or throttles them.
//
// Deliberately live navigation only. A full document load (every destination
// `ShellLive.nav_to/2` leaves as an `href`, and every reload) starts a new page
// with freshly loaded content, and dropping the reader into the middle of it is
// a promise this cannot keep. That is also why the offsets live in a plain map
// and not in `sessionStorage`: a map dies with the document, which is exactly
// as long as anything here would ever consult it — and it costs no serializing
// on the press, no quota, and no eviction policy.
//
// `/feed` is the one that matters and it is safe to restore: it re-mounts with
// the same first page, and new posts wait behind the "Show N new posts" pill
// instead of pushing the timeline down.

import { plainPress } from "./util"

const left = new Map()

// `phx:navigate` is dispatched one line too early to act on: LiveView has put
// the new (still empty) main element into the document, but the join's render —
// `onDone()`, in the same `replaceMain` callback — has not run yet. Measured on
// a phone viewport: the page is exactly one viewport tall at the event and its
// full height by the next macrotask (/notifications 812 -> 1289, /feed 812 ->
// 3596), because that render is synchronous and finishes before this task ends.
//
// So the first `scrollTo` runs straight away — for a page with nothing
// remembered it IS the reset, and a reset must not wait on anything — and the
// offset is put back on the next macrotask. `setTimeout` rather than
// `requestAnimationFrame` because frames are suspended while a tab is hidden,
// and a navigation the server pushes can land in a tab nobody is looking at.
//
// The two further attempts are for a page whose last stretch of height arrives
// after its markup (a stream, an image taking its box). They stop the moment
// somebody else moves the page: a reader who starts scrolling inside this
// window means it more than we do — and, for a plain reset, on the first call,
// since `scrollY` cannot fall short of 0.
const RESTORE_RETRIES = 2
const RESTORE_INTERVAL = 16

function restore(y, retries = 0) {
  window.scrollTo(0, y)
  if (window.scrollY >= y || retries >= RESTORE_RETRIES) return

  const placed = window.scrollY
  window.setTimeout(() => {
    if (window.scrollY === placed) restore(y, retries + 1)
  }, RESTORE_INTERVAL)
}

// Bubble phase on `document`, and registered after `scroll_top_tab.js`, so a
// press that the Feed tab's back-to-top face has taken for itself arrives here
// already prevented — nothing is being left, so there is nothing to remember.
// `plainPress` also rules out the modified click that opens the destination in
// a new tab: this page is not going anywhere, and recording where it happened
// to be scrolled would overwrite the offset the reader will come back to.
document.addEventListener("click", (event) => {
  if (!plainPress(event)) return
  if (!event.target.closest?.(`a[data-phx-link="redirect"]`)) return

  left.set(window.location.pathname, window.scrollY)
})

window.addEventListener("phx:navigate", ({ detail }) => {
  // A patch is the same page under a new URL (the notifications pager, a
  // message thread): it has always left the scroll alone and should keep doing
  // so. A pop is back/forward, where LiveView restores that history entry's own
  // offset itself.
  if (detail.patch || detail.pop) return

  restore(left.get(new URL(detail.href, window.location.origin).pathname) || 0)
})
