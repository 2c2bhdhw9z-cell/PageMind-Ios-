// PageMind Safari Web Extension — background script (Manifest V3).
// Receives messages from content.js and forwards page text to the native
// app via the Safari Web Extension handler. Also serves the popup.

function extractPageText(tabId) {
  return browser.tabs.sendMessage(tabId, { type: "extractPage" });
}

browser.runtime.onMessage.addListener((message, sender) => {
  if (message && message.type === "pageText") {
    // Forward to the native handler (SafariWebExtensionHandler.swift),
    // which stores the page in the shared App Group for the main app.
    return browser.runtime.sendNativeMessage({ type: "pageText", ...message });
  }
  return Promise.resolve({ received: true });
});
