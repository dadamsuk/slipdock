// PostHog product analytics, only when an admin has filled in a project key.
//
// The server says so with <meta name="posthog"> in the root layout, and puts
// nothing there otherwise — so without a key this does nothing at all, and no
// request goes anywhere. With one, it does what PostHog's own snippet does
// (which cannot be pasted in: this app allows no inline script): leave a stub
// queue at window.posthog holding the init call, then load PostHog's script,
// which finds the stub and replays it.

export function posthogConfig(doc) {
  const meta = doc.querySelector('meta[name="posthog"]')
  const key = meta && meta.getAttribute("content")
  if (!key) return null

  return {
    key,
    host: meta.getAttribute("data-host"),
    assets: meta.getAttribute("data-assets"),
  }
}

export function installPosthog(win, doc) {
  const config = posthogConfig(doc)
  if (!config || win.posthog) return false

  const options = {
    api_host: config.host,
    // Pageviews on every LiveView navigation, not only on full page loads.
    defaults: "2025-05-24",
    person_profiles: "identified_only",
    respect_dnt: true,
  }

  const stub = []
  stub.__SV = 1
  stub.people = []
  stub._i = [[config.key, options, "posthog"]]
  win.posthog = stub

  const script = doc.createElement("script")
  script.async = true
  script.crossOrigin = "anonymous"
  script.src = `${config.assets}/static/array.js`
  doc.head.appendChild(script)
  return true
}
