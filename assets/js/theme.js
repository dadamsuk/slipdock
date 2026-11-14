// Sets data-theme before the first paint, so the page never flashes the wrong
// one. Its own file rather than an inline <script> because the
// Content-Security-Policy allows script from this origin only (see
// SlipdockWeb.Plugs.ContentSecurityPolicy), and because it must run before
// app.js finishes loading.
import {restorePane} from "./wiki_pane.js"
import {restoreLabelWidth} from "./timeline_labels.js"
import {syncThemeColor} from "./theme_color.js"
// Where storage is blocked, reading it throws: storage.js guards every touch,
// so the listeners below are still registered and the theme still follows
// the system (#2882).
import {storage, read, write} from "./storage.js"

// The wiki tree's width, and whether it is folded away, for the same reason.
restorePane(document.documentElement, storage());
// The timeline's title column width (#1732), likewise.
restoreLabelWidth(document.documentElement, storage());

(() => {
  const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";

  const setTheme = (theme) => {
    if (theme === "system") {
      write("phx:theme", null);
      document.documentElement.setAttribute("data-theme", systemTheme());
      document.documentElement.setAttribute("data-theme-source", "system");
    } else {
      write("phx:theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
      document.documentElement.setAttribute("data-theme-source", "user");
    }
    try { syncThemeColor() } catch (_e) {}
  };
  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(read("phx:theme") || "system");
  } else {
    try { syncThemeColor() } catch (_e) {}
  }
  window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"));
  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));

  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
    if (document.documentElement.getAttribute("data-theme-source") === "system") {
      document.documentElement.setAttribute("data-theme", systemTheme());
    }
    try { syncThemeColor() } catch (_e) {}
  });
})();
