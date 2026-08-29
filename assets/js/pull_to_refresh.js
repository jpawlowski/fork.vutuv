import { reducedMotion } from "./util"

// Pull to refresh (issue #1730).
//
// Content already arrives by itself over PubSub, so this gesture is not a
// transport — it is a **reassurance**. It answers "have I seen everything?",
// which no push channel can answer, and it is the single most over-learned
// interaction on a phone: its absence reads as breakage even when nothing is
// broken.
//
// Two rules the implementation is built around.
//
// **Never `location.reload()`.** That throws away the LiveView, rebuilds the
// socket and re-fetches the whole document — the "refresh" would cost more
// than the state it refreshes, and on a slow line it is visibly worse than
// having no gesture at all. The release pushes `pwa:refresh` over the existing
// socket and the page re-queries its own list; the chrome, the scroll
// container and the socket all stay.
//
// **It is opt-in per page.** A page that does not implement
// `handle_event("pwa:refresh", …)` simply does not render the hook's element,
// so the gesture never appears where it would do nothing. `/feed`,
// `/messages` and `/notifications` implement it today.
//
// The indicator is built here rather than rendered by the server, and it wears
// its animation through the Web Animations API rather than a keyframe: the
// element only ever exists in a document whose bundle contains this file, so
// there is nothing for an older stylesheet to get wrong. The colours are
// ordinary Tailwind utilities — `@source "../js"` in `app.css` means classes
// written here are scanned like any others.

// Finger travel is halved and hard-capped, which is what reads as "native": a
// 1:1 drag feels like the page came loose. The threshold is measured on the
// resisted distance, i.e. ~140px of actual finger.
const RESISTANCE = 0.5
const THRESHOLD = 70
const MAX = 120

// A dead line must not leave the spinner up forever. Long enough that a slow
// answer still lands inside it.
const TIMEOUT_MS = 8000

const PullToRefresh = {
  mounted() {
    // `data-pull-scroller="self"` says this element scrolls itself (the
    // messages page is a full-viewport chat and the document does not move);
    // otherwise the document is the scroller. A gesture that engages on the
    // wrong element is worse than none, so this is stated rather than guessed.
    this.scroller =
      this.el.dataset.pullScroller === "self" ? this.el : document.documentElement

    // Chrome runs its own pull-to-refresh on the same gesture. `contain` stops
    // it from firing underneath ours — set here, not in the stylesheet, so it
    // is scoped to exactly the pages that replace it and lifted again when
    // this hook goes away.
    this.overscrollWas = this.scroller.style.overscrollBehaviorY
    this.scroller.style.overscrollBehaviorY = "contain"

    this.pull = null
    this.busy = false
    this.moving = false
    this.frame = null
    this.pending = 0
    this.indicator = null
    this.spin = null

    this.onStart = (e) => this.begin(e)
    // Non-passive, because the point is to `preventDefault()` the native
    // scroll while the finger is pulling. Same reason the composer's reorder
    // drag registers one — and the reason it is NOT registered up front: a
    // non-passive touchmove on a page-sized element makes the browser wait for
    // the main thread before it may scroll at all, so leaving one standing
    // would tax every ordinary scroll of the feed for a gesture that starts
    // only at the very top. It goes on when a pull becomes possible and comes
    // off again with the finger.
    this.onMove = (e) => this.track(e)
    this.onEnd = () => this.release()

    this.el.addEventListener("touchstart", this.onStart, { passive: true })
    this.el.addEventListener("touchend", this.onEnd)
    this.el.addEventListener("touchcancel", this.onEnd)
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this.onStart)
    this.el.removeEventListener("touchend", this.onEnd)
    this.el.removeEventListener("touchcancel", this.onEnd)
    this.unwatchMoves()
    this.scroller.style.overscrollBehaviorY = this.overscrollWas
    clearTimeout(this.timer)
    if (this.frame) cancelAnimationFrame(this.frame)
    if (this.indicator) this.indicator.remove()
  },

  watchMoves() {
    if (this.moving) return
    this.moving = true
    this.el.addEventListener("touchmove", this.onMove, { passive: false })
  },

  unwatchMoves() {
    if (!this.moving) return
    this.moving = false
    this.el.removeEventListener("touchmove", this.onMove)
  },

  atTop() {
    return this.scroller.scrollTop <= 0
  },

  begin(e) {
    if (this.busy || e.touches.length !== 1) return
    if (!this.atTop()) return
    const touch = e.touches[0]
    // The container cannot move while the pull runs (the native scroll is
    // prevented), so its top edge is measured once here. Reading it per move
    // would be a layout flush per frame, right after this frame's writes.
    this.pull = {
      y: touch.clientY,
      x: touch.clientX,
      top: Math.max(0, this.el.getBoundingClientRect().top),
      armed: false,
      crossed: false,
    }
    this.watchMoves()
  },

  track(e) {
    if (!this.pull || e.touches.length !== 1) return

    const touch = e.touches[0]
    const dy = touch.clientY - this.pull.y
    const dx = Math.abs(touch.clientX - this.pull.x)

    // The first movement decides whose gesture this is. Upward, or more
    // sideways than down, and it was never ours — let the browser scroll.
    if (!this.pull.armed) {
      if (dy <= 0 || dy < dx) return this.collapse()
      this.pull.armed = true
    }

    // Momentum can have carried the container off the top between frames.
    if (!this.atTop()) return this.collapse()

    e.preventDefault()
    const distance = Math.min(MAX, dy * RESISTANCE)
    this.draw(distance)

    // The confirmation has to arrive at the moment the threshold is crossed,
    // not on release — by then the decision is already made. Android taps;
    // iOS ignores `vibrate` without error.
    const crossed = distance >= THRESHOLD
    if (crossed && !this.pull.crossed && navigator.vibrate) navigator.vibrate(10)
    this.pull.crossed = crossed
  },

  release() {
    if (!this.pull) return
    const armed = this.pull.crossed
    const top = this.pull.top
    this.pull = null
    this.unwatchMoves()
    if (!armed) return this.collapse()

    // Hold the spinner until the server answers, then collapse. A `noreply`
    // still acks, so this callback runs on every handled event.
    this.busy = true
    this.paint(top, THRESHOLD, true)
    this.timer = setTimeout(() => this.finish(), TIMEOUT_MS)
    this.pushEvent("pwa:refresh", {}, () => this.finish())
  },

  finish() {
    clearTimeout(this.timer)
    this.busy = false
    this.collapse()
  },

  collapse() {
    this.pull = null
    this.unwatchMoves()
    if (this.busy || !this.indicator) return
    this.indicator.style.opacity = "0"
    this.indicator.style.transform = "translate(-50%, 0) scale(0.8)"
    if (this.spin) {
      this.spin.cancel()
      this.spin = null
    }
  },

  // The indicator has to appear DURING the pull, not after release: the whole
  // point is that it tells you the gesture exists before you commit to it.
  //
  // A touch screen can deliver moves faster than it paints (120 Hz ProMotion,
  // coalesced Android events), so the distance is stashed and written once per
  // frame instead of once per event.
  draw(distance) {
    // The frame reads the LATEST distance, not the one that scheduled it —
    // otherwise a coalesced burst paints the first value of the burst and the
    // indicator lags the finger by a frame.
    this.pending = distance
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      if (this.pull) this.paint(this.pull.top, this.pending, false)
    })
  },

  // Only `transform` and `opacity` are written, and both are compositor
  // properties: the offset of the container's top edge is folded into the
  // translate rather than set as `top`, which would dirty layout every frame.
  paint(top, distance, spinning) {
    const node = this.indicator || this.build()

    node.style.opacity = `${Math.min(1, distance / THRESHOLD)}`
    node.style.transform = `translate(-50%, ${top + distance}px) scale(${Math.min(1, 0.6 + distance / THRESHOLD / 2)})`

    if (spinning) {
      // A reader who asked for less motion still gets the spinner's presence,
      // just not its rotation (`reducedMotion` in util.js is the app's gate).
      if (!this.spin && !reducedMotion()) {
        this.spin = node.firstChild.animate(
          [{ transform: "rotate(0deg)" }, { transform: "rotate(360deg)" }],
          { duration: 800, iterations: Infinity }
        )
      }
    } else {
      // Before release the arc turns with the finger, so the control reports
      // how far along the gesture is rather than only whether it fired.
      node.firstChild.style.transform = `rotate(${distance * 3}deg)`
    }
  },

  build() {
    const node = document.createElement("div")
    node.setAttribute("aria-hidden", "true")
    node.className =
      "pointer-events-none fixed left-1/2 top-0 z-20 flex h-9 w-9 items-center justify-center " +
      "rounded-full bg-white text-brand-600 shadow-md ring-1 ring-slate-200 " +
      "dark:bg-slate-800 dark:text-brand-300 dark:ring-slate-700"
    if (!reducedMotion()) {
      node.style.transition = "opacity 200ms ease-out, transform 200ms ease-out"
    }
    node.style.opacity = "0"
    node.innerHTML =
      '<svg class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">' +
      '<path stroke-linecap="round" d="M21 12a9 9 0 1 1-6.219-8.56" /></svg>'
    document.body.appendChild(node)
    this.indicator = node
    return node
  },
}

export default PullToRefresh
