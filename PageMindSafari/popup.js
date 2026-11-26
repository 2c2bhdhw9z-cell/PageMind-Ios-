// PageMind Safari Web Extension — popup script.
// The popup is a thin shell: "Save this page" asks the active tab's
// content script for its cleaned text, which then flows to the native
// handler and into the main app's Library on next launch.

document.getElementById("save").addEventListener("click", async () => {
  const status = document.getElementById("status");
  try {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    if (!tab || tab.id === undefined) { status.textContent = "No active tab."; return; }
    await browser.tabs.sendMessage(tab.id, { type: "savePage" });
    status.textContent = "Saved — open PageMind to ask about it.";
  } catch (e) {
    status.textContent = "Could not save this page. Try the in-app browser instead.";
  }
});

document.getElementById("open").addEventListener("click", () => {
  browser.tabs.create({ url: "pagemind://library" });
});
