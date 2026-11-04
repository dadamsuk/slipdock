// Sets data-theme before the first paint, so the page never flashes the wrong
// one. Its own file rather than an inline <script> because the
// Content-Security-Policy allows script from this origin only (see
// SlipdockWeb.Plugs.ContentSecurityPolicy), and because it must run before
// app.js finishes loading.
import {restorePane} from "./wiki_pane"
import {syncThemeColor} from "./theme_color"

// The wiki tree's width, and whether it is folded away, for the same reason.
try { restorePane(document.documentElement, localStorage) } catch (_e) {}

(() => {
  const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";

  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem("phx:theme");
      document.documentElement.setAttribute("data-theme", systemTheme());
      document.documentElement.setAttribute("data-theme-source", "system");
    } else {
      localStorage.setItem("phx:theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
      document.documentElement.setAttribute("data-theme-source", "user");
    }
    try { syncThemeColor() } catch (_e) {}
  };
  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(localStorage.getItem("phx:theme") || "system");
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
