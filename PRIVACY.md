# PageMind Privacy Policy (v1 — Day 1–2 build)

Last updated: 2026-11-26.

## Short version

PageMind collects nothing. There is no account, no analytics SDK, and no tracking. Your pages, chats, and API keys stay on your device. The only data that ever leaves your device is what you yourself send to the AI provider you chose — and web-search queries, if you use web search.

## What stays on your device

- Saved pages, reader text, chats, collections, and settings — stored locally with SwiftData.
- API keys — stored in the iOS Keychain. They are never written to a file, never logged, and never sent to PageMind (there is no PageMind server).
- Data shared from Safari / other apps via the Share Extension or Safari Web Extension — stored in the App Group shared container on your device, imported into the app on launch, and never uploaded anywhere.

## What leaves your device (only when you ask it to)

- **Chat requests:** the text you send, plus the page/PDF/search context you attached, goes to the AI provider you selected in Settings (OpenRouter, OpenAI, Anthropic, Google, Groq, your local Ollama/LM Studio server, or your custom endpoint). That provider's own privacy policy applies to that request. PageMind adds an `X-Title: PageMind` header to OpenRouter requests for attribution.
- **Web search:** your search query goes to Brave Search (if you added a Brave key) or DuckDuckGo (no key). Results come back with titles and URLs for citations.
- **Model list:** the app fetches the public OpenRouter model list (`https://openrouter.ai/api/v1/models`). No key or personal data is sent with that request.
- **Purchases (later):** when Pro is sold through the App Store, Apple handles payment. PageMind receives only the StoreKit transaction status (whether Pro is active). No payment details ever touch the app.

## What PageMind does not do

- No account, no sign-in, no email collection.
- No analytics, crash-reporting, or advertising SDKs in v1.
- No tracking across apps or websites (the privacy manifest declares `NSPrivacyTracking: false` and no collected data types).
- No data is sold or shared with third parties by PageMind.

## Children

PageMind is not directed at children under 13.

## Changes

If this policy changes (for example, if sync or hosted AI is added in a later version), this file and the App Store listing will be updated before the change ships.

## Contact

Questions about this policy: use the support link on the App Store listing once published. In the meantime, this file in the repo is the current policy.
