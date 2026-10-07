// PostHog product analytics, only when an admin has filled in a project key.
//
// The server says so with <meta name="posthog"> in the root layout, and puts
// nothing there otherwise — so without a key this does nothing at all, and no
// request goes anywhere. With one, two things have to be right, and both were
// wrong before:
//
//   * The stub. Until PostHog's own script has loaded, window.posthog is a
//     stand-in. PostHog's official snippet makes that stand-in queue every
//     method call — capture, identify, … — so a call made before the script
//     arrives is replayed once it does, not thrown away. The hand-rolled stub
//     this replaced defined no methods at all, so any posthog.capture() in that
//     window threw "posthog.capture is not a function" and the event was lost.
//     We use the official snippet verbatim (it cannot be pasted into the page
//     as PostHog documents it: this app allows no inline <script>).
//
//   * Pageviews. This is a LiveView app: after the first load, moving around is
//     history.pushState, not a new document. PostHog's automatic pageview is
//     tied to how it chooses to watch history, which covers LiveView's live
//     navigation unreliably — so we turn it off (capture_pageview: false) and
//     send $pageview ourselves: once on first load, and once per LiveView
//     navigation (the phx:navigate event). That is exactly one per view, with
//     no double counting between our capture and PostHog's.

export function posthogConfig(doc) {
  const meta = doc.querySelector('meta[name="posthog"]')
  const key = meta && meta.getAttribute("content")
  if (!key) return null

  return {
    key,
    host: meta.getAttribute("data-host"),
    assets: meta.getAttribute("data-assets"),
    // The admin's Do-Not-Track choice (Slipdock.Settings). Present and "false"
    // means honour visitors who ask not to be tracked no longer; anything else,
    // including a missing attribute, keeps the safe default of respecting it.
    respectDnt: meta.getAttribute("data-respect-dnt") !== "false",
  }
}

// PostHog's official loader snippet (https://posthog.com/docs/libraries/js),
// verbatim. It leaves a method-queue stub at window.posthog and, on init, loads
// PostHog's array.js from the assets host, which replays whatever was queued.
function loadSnippet(win, doc) {
  !(function (t, e) {
    var o, n, p, r
    e.__SV ||
      ((win.posthog = e),
      (e._i = []),
      (e.init = function (i, s, a) {
        function g(t, e) {
          var o = e.split(".")
          2 == o.length && ((t = t[o[0]]), (e = o[1])),
            (t[e] = function () {
              t.push([e].concat(Array.prototype.slice.call(arguments, 0)))
            })
        }
        ;((p = t.createElement("script")).type = "text/javascript"),
          (p.crossOrigin = "anonymous"),
          (p.async = !0),
          (p.src =
            s.api_host.replace(".i.posthog.com", "-assets.i.posthog.com") +
            "/static/array.js"),
          (r = t.getElementsByTagName("script")[0]).parentNode.insertBefore(p, r)
        var u = e
        for (
          void 0 !== a ? (u = e[a] = []) : (a = "posthog"),
            u.people = u.people || [],
            u.toString = function (t) {
              var e = "posthog"
              return "posthog" !== a && (e += "." + a), t || (e += " (stub)"), e
            },
            u.people.toString = function () {
              return u.toString(1) + ".people (stub)"
            },
            o =
              "init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagPayload isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey getNextSurveyStep identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug getPageViewId captureTraceFeedback captureTraceMetric".split(
                " "
              ),
            n = 0;
          n < o.length;
          n++
        )
          g(u, o[n])
        e._i.push([i, s, a])
      }),
      (e.__SV = 1))
  })(doc, win.posthog || [])
}

export function installPosthog(win, doc) {
  const config = posthogConfig(doc)
  if (!config || win.__posthogInstalled) return false
  win.__posthogInstalled = true

  loadSnippet(win, doc)

  win.posthog.init(config.key, {
    api_host: config.host,
    defaults: "2025-05-24",
    person_profiles: "identified_only",
    respect_dnt: config.respectDnt,
    // We send $pageview ourselves (see capturePageview) so that LiveView's live
    // navigation is counted once and only once; PostHog's own pageview would
    // either miss those navigations or race ours.
    capture_pageview: false,
  })

  // The first view.
  capturePageview(win)
  // Every LiveView live navigation (live_patch / live_redirect / push_navigate)
  // dispatches phx:navigate on the window once the URL has changed.
  win.addEventListener("phx:navigate", () => capturePageview(win))

  return true
}

// Sends one $pageview for the window's current URL, skipping a repeat of the
// URL it last sent so a navigation that lands where we already are — or two
// events for one view — cannot double count.
export function capturePageview(win) {
  const url = win.location && win.location.href
  if (url && url === win.__posthogLastPageview) return false
  win.__posthogLastPageview = url

  if (win.posthog && typeof win.posthog.capture === "function") {
    win.posthog.capture("$pageview")
    return true
  }
  return false
}
