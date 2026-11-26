// PageMind Safari Web Extension — content script.
// Adds a small floating "Ask PageMind" button to every page. On click it
// extracts the page title and cleaned readable text (script, style and
// navigation elements stripped) and sends it to the native handler via
// browser.runtime.sendMessage({ type: "pageText", title, text }).
// It also listens for messages asking it to highlight the selected text.
// Plain JavaScript, no dependencies.

(function () {
  "use strict";

  function cleanText() {
    var clone = document.body.cloneNode(true);
    var selectors = ["script", "style", "nav", "header", "footer", "noscript", "iframe", "svg"];
    selectors.forEach(function (selector) {
      clone.querySelectorAll(selector).forEach(function (el) { el.remove(); });
    });
    var text = clone.innerText || "";
    return text.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  }

  function sendPageText() {
    var message = {
      type: "pageText",
      title: document.title || "",
      url: window.location.href,
      text: cleanText()
    };
    if (typeof browser !== "undefined" && browser.runtime && browser.runtime.sendMessage) {
      browser.runtime.sendMessage(message);
    }
  }

  function addButton() {
    if (document.getElementById("pagemind-ask-button")) { return; }
    var button = document.createElement("button");
    button.id = "pagemind-ask-button";
    button.type = "button";
    button.textContent = "Ask PageMind";
    button.setAttribute("aria-label", "Ask PageMind about this page");
    button.style.cssText = [
      "position: fixed",
      "right: 16px",
      "bottom: 16px",
      "z-index: 2147483647",
      "padding: 10px 16px",
      "border: none",
      "border-radius: 999px",
      "background: #111827",
      "color: #ffffff",
      "font: 600 14px/1 -apple-system, sans-serif",
      "box-shadow: 0 4px 16px rgba(0,0,0,0.3)",
      "cursor: pointer"
    ].join(";");
    button.addEventListener("click", function () {
      button.textContent = "Sent to PageMind";
      sendPageText();
      window.setTimeout(function () { button.textContent = "Ask PageMind"; }, 2000);
    });
    document.documentElement.appendChild(button);
  }

  // Messages from the popup / background script.
  if (typeof browser !== "undefined" && browser.runtime && browser.runtime.onMessage) {
    browser.runtime.onMessage.addListener(function (message) {
      if (!message) { return; }
      // Popup "Save this page": extract and send the page to the native side.
      if (message.type === "savePage") {
        sendPageText();
        return Promise.resolve({ saved: true });
      }
      if (message.type === "extractPage") {
        return Promise.resolve({
          title: document.title || "",
          url: window.location.href,
          text: cleanText()
        });
      }
      if (message.type !== "highlightSelection") { return; }
      var selection = window.getSelection();
      if (!selection || selection.rangeCount === 0) { return; }
      var range = selection.getRangeAt(0);
      var span = document.createElement("mark");
      span.setAttribute("data-pagemind-highlight", "true");
      span.style.backgroundColor = "#fde047";
      try {
        range.surroundContents(span);
      } catch (e) {
        // Selections spanning multiple elements cannot be wrapped in one
        // <mark>; leave the selection as-is rather than breaking the page.
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", addButton);
  } else {
    addButton();
  }
})();
