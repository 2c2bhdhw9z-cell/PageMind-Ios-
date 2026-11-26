# PageMind — AI That Reads With You

PageMind is a native Swift iOS 17+ app: save any page, PDF, or video transcript, ask questions about it, and keep asking about everything you've ever saved — with citations, in plain language, with your own AI key or free models. No account required.

- **In-app browser** (WKWebView) + on-device Reader Mode
- **Page-aware chat** with 100+ models via OpenRouter, OpenAI, Anthropic, Gemini, Groq, local Ollama / LM Studio, or any OpenAI-compatible endpoint
- **Free web search** (Brave API or DuckDuckGo, no key needed) with cited sources
- **Free PDF chat** — on-device PDFKit text extraction, up to 10 PDFs per chat
- **Web Memory** — every saved page is indexed locally and searchable
- **Share Extension + Safari Web Extension + Widgets**
- **Privacy-first** — keys in the iOS Keychain, data on-device, no analytics, no account

Pro (StoreKit 2, `$4.99/mo` or `$24.99 Lifetime`, `$19.99` at launch) unlocks the Browser Agent, side-by-side model compare, Morning Brief, and Deep Research. See `PRIVACY.md` and `BUILD-NOTES.md`.

> Status: Day 1–2 scaffold + MVP core + Day 8–13 polish and Pro features. It has **not** been compiled yet — there is no Xcode on the build VM. The first real compile happens on the GitHub runner after the repo is created. See `BUILD-NOTES.md` for exactly what is verified, what is a stub, and what is known-broken.

## Repo layout

```
PageMind/                 Main app (SwiftUI, SwiftData, iOS 17+, Swift 6)
  PageMindApp.swift       @main, TabView: Browser / Library / Chat / Settings
  Models.swift            SwiftData: Chat, ChatMessage, SavedPage, CollectionModel
  AI/                     AIProvider protocol + OpenAI-compatible streaming client
                          + Anthropic / Gemini providers + OpenRouter model list
  Reader/                 Readability-style on-device page extraction
  Search/                 Brave Search API + DuckDuckGo fallback, with citations
  PDF/                    PDFKit text extraction
  Data/                   KeychainStore, AppSettings, WebMemorySearch,
                          PendingPageImporter (Share/Safari queue import)
  Views/                  Browser, Chat, Library, Settings, Onboarding,
                          HighlightToolbar
  Pro/                    StoreManager (StoreKit 2), PaywallView,
                          ProFeatures (clearly-marked stubs)
PageMindShare/            Share Extension — saves URL/text to the App Group queue
PageMindSafari/           Safari Web Extension — content.js, popup, background.js,
                          native handler
PageMindWidgets/          WidgetKit — saved-today count + recent pages
.github/workflows/       build.yml (push) + ipa.yml (manual / tag v*)
```

## Build locally (on a Mac with Xcode 16)

```bash
git clone <your-private-repo-url>
cd PageMind-iOS
open PageMind.xcodeproj
```

- Pick the `PageMind` scheme, an iPhone simulator or your device, and Run.
- **No signing is configured in v1.** The project sets `CODE_SIGNING_ALLOWED=NO`, so it builds unsigned. To run on a real device through Xcode you will need to add your own team/signing in Xcode (Signing & Capabilities) — or use the CI `.ipa` below and sideload it.
- App Groups (`group.com.pagemind.app`) are referenced in code but there is no entitlements file yet. If the group isn't provisioned, the app falls back to an in-memory SwiftData store (pages won't persist) and the extensions' shared queue won't reach the app. Add the App Group capability + entitlements when Apple Developer is bought.

## CI — GitHub runners

| Workflow | Trigger | Result |
|---|---|---|
| `build.yml` | every push / PR | `xcodebuild build` (Debug, unsigned). SwiftLint is best-effort and never fails the build. |
| `ipa.yml` | manual dispatch, or tag `v*` | Archives (Release, unsigned), zips `Payload/PageMind.app` into `PageMind-unsigned.ipa`, uploads it as a workflow artefact (30 days). |

No secrets are needed for either workflow in v1. No provisioning profiles, no certificates.

## Sideload the .ipa (your own tool)

1. Run the `ipa.yml` workflow (Actions → Build unsigned .ipa → Run workflow), or push a `v*` tag.
2. Download the `PageMind-unsigned-ipa` artefact, unzip it to get `PageMind-unsigned.ipa`.
3. Re-sign + install it with your own sideload tool (e.g. AltStore / SideStore / TrollStore-style tooling, or `codesign` + install via your method).
4. The app runs without an Apple Developer account. StoreKit purchases will **not** work while sideloaded — Pro stays locked and the paywall says so. That is expected until App Store Connect products exist.

## Add an AI key (in the app)

Settings → Provider → pick one → paste the key. Keys are stored in the iOS Keychain, never in code, never logged.

- **Free, no key:** pick OpenRouter and use the default model `openrouter/free`. OpenRouter free models are capped at 50 requests/day (1,000/day after a one-time $10 credit purchase on your OpenRouter account). Free models change often — the app fetches the live list.
- **OpenRouter:** https://openrouter.ai/keys
- **OpenAI / Anthropic / Gemini / Groq:** paste your provider key in Settings.
- **Local (free):** Ollama or LM Studio on your Mac — set the base URL in Settings (default `http://localhost:11434/v1`). The phone and the Mac must be on the same network; use the Mac's LAN IP, not `localhost`, from the phone.

## What's working vs what's a stub

Working (code-complete, untested on device): browser + Reader, chat streaming across 7 provider kinds, OpenRouter live model list, web search with citations, PDF text extraction, Library + Web Memory keyword search, Share/Safari extensions (queue + import wired), widgets, Keychain + settings, onboarding, StoreKit 2 scaffolding, Browser Agent (click/type/scroll, approval-gated), side-by-side model compare, Morning Brief scheduling, Deep Research reports, vision chat, YouTube transcripts.

Stub / not built yet: semantic Web Memory (keyword search only for now — on-device embeddings are v1.1), Custom Skills/MCP (v1.1), voice input + read-aloud, App Shortcuts. Notion/Obsidian export was removed from the paywall on 2026-11-26 — the user doesn't use those apps — and is not promised. Export is Markdown / PDF / Apple Notes share.

Full list: `BUILD-NOTES.md`.

## Pricing (planned, App Store)

- Pro Monthly: `$4.99` — product `pagemind.pro.monthly`
- Pro Lifetime: `$24.99` (`$19.99` at launch) — product `pagemind.pro.lifetime`
- Pro is a feature unlock, not AI usage. Your AI key is still yours; PageMind sells no credits in v1.

## Privacy

No account, no analytics SDK, no tracking. See `PRIVACY.md`. The only data that ever leaves the device is what you send to the AI provider *you* chose, and web-search queries to Brave/DuckDuckGo.
