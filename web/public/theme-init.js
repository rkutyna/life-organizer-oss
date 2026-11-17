// Apply the theme before first paint to avoid a flash. Mirrors src/app/theme.tsx.
(function () {
  var pref = "system";
  try {
    pref = JSON.parse(localStorage.getItem("lo.theme")) || "system";
  } catch (e) {}
  var dark =
    pref === "dark" ||
    (pref === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  if (dark) document.documentElement.classList.add("dark");
})();
