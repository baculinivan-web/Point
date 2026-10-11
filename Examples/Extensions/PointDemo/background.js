browser.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type !== "page-visit") return false;
  (async () => {
    const { visits = 0 } = await browser.storage.local.get("visits");
    await browser.storage.local.set({ visits: visits + 1 });
    const tabs = await browser.tabs.query({});
    return { visits: visits + 1, tabs: tabs.length };
  })().then(reply).catch(error => reply({ error: String(error) }));
  return true;
});
