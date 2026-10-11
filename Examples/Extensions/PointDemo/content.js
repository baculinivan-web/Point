browser.runtime.sendMessage({ type: "page-visit" }).then(result => {
  const badge = document.createElement("div");
  badge.id = "point-demo-badge";
  badge.textContent = result?.error || `Point Demo · ${result?.visits ?? "?"} visits · ${result?.tabs ?? "?"} tabs`;
  document.body.append(badge);
});
