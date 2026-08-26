defmodule Vutuv.PageScreenshot.ConsentSweep do
  @moduledoc """
  The last thing that happens before the shutter: whatever consent dialog is
  still standing gets hidden.

  `Vutuv.PageScreenshot.Consent` clears the dialogs `@duckduckgo/autoconsent`
  has a rule for, and that is most of them. What it cannot do is keep up with a
  site that redesigns its consent manager: `zdf.de` is the example this was
  written against — the vendored rule still looks for `#zdf-cmp-banner-sdk`,
  which the current page does not have, so autoconsent detects nothing, reports
  nothing, and the capture is a picture of "Deine Datenschutzeinstellungen".
  A stale rule and an unlisted site fail *identically*, and both fail silently.

  So the rule set gets a floor under it. This is a single `Runtime.evaluate` in
  the top frame, run just before the screenshot: find the elements that are
  covering the page, decide whether they are a consent notice, and set
  `display: none` on the ones that are.

  ## It hides, it never clicks

  Autoconsent clicks **reject**. This one clicks nothing at all, and that is
  deliberate rather than lazy: a text-matched button is a guess, and the button
  next to the one you meant says "Accept". Hiding is the more conservative
  answer *and* the more private one — nothing is consented to, no CMP cookie is
  written, and the whole edit lives for the few hundred milliseconds the
  throwaway capture browser has left to live. The member's own browser is never
  involved; only the picture changes.

  It follows that this does not help with a **consent-or-pay wall** (heise
  offers free readers no reject at all): the page behind it is not the article,
  so hiding the wall reveals nothing worth photographing. Those sites belong on
  `Vutuv.ScreenshotBlocklist`, which is where heise already is.

  ## What counts as a consent notice

  Three gates, and a candidate has to pass all of them — a false positive here
  deletes part of a page from the picture, so recall is worth less than
  precision:

    1. **It is laid over the page.** `position: fixed` or `sticky`, visible, and
       covering at least 4% of the viewport. Ordinary content is neither.
    2. **It talks about consent.** Its text matches a cookie/consent/privacy
       vocabulary in the languages this reaches (German and English first, then
       the other EU languages a member is likely to link to).
    3. **It offers a consent action.** A button or link that says accept,
       agree, allow, reject, decline — the one thing every consent dialog has
       and an article about cookies does not. Without this gate a news story
       mentioning the GDPR under a sticky header is a candidate.

  A cross-origin CMP iframe (Sourcepoint and friends) can pass none of the text
  gates, because its text is not ours to read. Those, and the shadow-DOM roots
  some CMPs mount (Usercentrics, OneTrust), are matched on the *element's own*
  id, class, title and `src` against the known CMP vocabulary instead — a
  `#usercentrics-root` laid over the page is not ambiguous.

  Two follow-ups only run once a dialog was actually found, so a page with no
  dialog is never touched: the dimming **backdrop** behind it (a full-viewport
  fixed layer with no text of its own) is hidden with it, and the **scroll
  lock** on `html`/`body` is released, along with any blur filter over the
  page. Hiding the dialog while leaving the page dimmed and blurred would trade
  one useless picture for another.

  Returns the list of what it hid, so the caller can log a page that needed
  this — a site that lands here is a site whose autoconsent rule has gone
  stale.
  """

  # Kept as one self-contained expression (no globals, no listeners, one return
  # value) because that is all `Runtime.evaluate` gives us: it runs once, in a
  # page we do not control, and anything it leaves behind would ride along into
  # the screenshot.
  #
  # ~S: the source contains `#` and `\w`, neither of which is ours to interpolate.
  @js ~S"""
  (function () {
    var CONSENT = /(cookie|consent|einwillig|datenschutz|privatsph|zustimm|akzeptier|ablehn|tracking|dsgvo|gdpr|privacy|confidentialit|consentement|consentimiento|privacidad|informativa|toestemming|prywatno|samtykke|integritetspolicy)/i;
    var ACTION = /(akzeptier|zustimm|einverstanden|verstanden|erlaub|ablehn|accept|agree|allow|reject|decline|deny|consent|accepter|refuser|aceptar|rechazar|accetta|rifiuta|akkoord|weiger|zgadzam|odrzu|godk)/i;
    var CMP = /(consent|cookie|privacy|cmp|gdpr|sourcepoint|onetrust|cookielaw|usercentrics|didomi|trustarc|quantcast|sp-prod|sp_message|iubenda|borlabs|complianz|klaro|cookiebot|truste)/i;
    var MAX_NODES = 15000;
    var MIN_COVER = 0.04;
    var BACKDROP_COVER = 0.85;
    var MAX_DIALOG_TEXT = 5000;

    var vw = window.innerWidth;
    var vh = window.innerHeight;
    var area = vw * vh;
    var hidden = [];
    if (!area) return hidden;

    function elements() {
      var found = [];
      var roots = [document];
      while (roots.length && found.length < MAX_NODES) {
        var all = roots.shift().querySelectorAll('*');
        for (var i = 0; i < all.length && found.length < MAX_NODES; i++) {
          found.push(all[i]);
          if (all[i].shadowRoot) roots.push(all[i].shadowRoot);
        }
      }
      return found;
    }

    function cover(el) {
      var r = el.getBoundingClientRect();
      var w = Math.min(r.right, vw) - Math.max(r.left, 0);
      var h = Math.min(r.bottom, vh) - Math.max(r.top, 0);
      return w > 0 && h > 0 ? (w * h) / area : 0;
    }

    function text(el) {
      return (el.innerText || '').replace(/\s+/g, ' ').trim();
    }

    function named(el) {
      return [el.id, el.getAttribute('class'), el.getAttribute('title'),
              el.getAttribute('name'), el.getAttribute('src')].join(' ');
    }

    function offersConsentAction(el) {
      var actions = el.querySelectorAll('button,a,[role="button"],input[type="button"],input[type="submit"]');
      for (var i = 0; i < actions.length; i++) {
        var label = (actions[i].innerText || actions[i].value || '').trim();
        if (label && ACTION.test(label)) return true;
      }
      return false;
    }

    function isConsentNotice(el, body) {
      // The size ceiling holds for BOTH routes. A dialog is a dialog; an
      // element carrying a page's worth of text is the page, whatever its
      // class says — and `privacy`, `cookie` and `consent` are words a page
      // about them puts in its own container names. Hiding that is a blank
      // screenshot, which is worse than the banner. The iframes and shadow
      // hosts the name route exists for read as no text at all, so they are
      // untouched by it.
      if (body.length > MAX_DIALOG_TEXT) return false;
      if (CMP.test(named(el))) return true;
      if (!body) return false;
      return CONSENT.test(body) && offersConsentAction(el);
    }

    function hide(el, why) {
      el.style.setProperty('display', 'none', 'important');
      hidden.push(why + ':' + (el.tagName || '?').toLowerCase() +
                  (el.id ? '#' + el.id : '') +
                  (el.getAttribute('class') ? '.' + el.getAttribute('class').trim().split(/\s+/)[0] : ''));
    }

    var notices = [];
    var backdrops = [];

    elements().forEach(function (el) {
      var seen = cover(el);
      if (seen < MIN_COVER) return;
      var style = window.getComputedStyle(el);
      if (style.position !== 'fixed' && style.position !== 'sticky') return;
      // A `display: none` element has an all-zero rect, so the coverage gate
      // above already dropped it; these two keep theirs.
      if (style.visibility === 'hidden' || style.opacity === '0') return;
      // innerText flushes layout and is the most expensive call in here, so it
      // is read once and handed to both branches — the second read used to
      // land on exactly the worst elements, the full-viewport wrappers.
      var body = text(el);
      if (isConsentNotice(el, body)) notices.push(el);
      else if (seen >= BACKDROP_COVER && body.length < 2) backdrops.push(el);
    });

    if (!notices.length) return hidden;

    notices.forEach(function (el) { hide(el, 'notice'); });
    backdrops.forEach(function (el) { hide(el, 'backdrop'); });

    [document.documentElement, document.body].forEach(function (el) {
      if (!el) return;
      var style = window.getComputedStyle(el);
      if (style.overflow !== 'visible') el.style.setProperty('overflow', 'visible', 'important');
      if (style.position === 'fixed') el.style.setProperty('position', 'static', 'important');
      if (style.filter && style.filter !== 'none') el.style.setProperty('filter', 'none', 'important');
    });

    return hidden;
  })()
  """

  @doc """
  The JavaScript to evaluate in the top frame right before the screenshot.

  Answers an array naming what it hid (`"notice:div#radix-_r_2_"`), empty when
  the page carried no consent dialog — which is the common case and costs one
  layout pass. `Runtime.evaluate` is called with `returnByValue`, so the array
  arrives here as a list without either side spelling out JSON.
  """
  def expression, do: @js

  @doc """
  Reads what `expression/0` answered as a list of descriptions.

  Anything else — an evaluate that threw and returned no value, a reply shape
  we did not expect — is "nothing was hidden": the sweep is a cosmetic
  improvement on a best-effort capture, and there is no failure here worth
  giving up a screenshot over.
  """
  def hidden(value) when is_list(value), do: Enum.filter(value, &is_binary/1)

  def hidden(_value), do: []
end
