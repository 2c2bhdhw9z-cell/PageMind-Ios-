# PageMind — Build Notes (Day 1–2 scaffold + MVP core, Day 8–13 polish + Pro)

Date: 2026-11-26. Status: **scaffold + MVP core + Day 8–13 pass written. NOT compiled yet.**

## Day 8–13 pass (2026-11-26) — what was built

59 files in `~/workspace/pagemind/` (~6,040 Swift lines, up from 46 files / ~3,700 lines). Everything below is on top of the Day 1–2 tree; nothing was pushed to GitHub and no repo was created (the user creates `PageMind-iOS` when ready).

### Known issues fixed (from the Day 1–2 list)
- **(4) Gemini key in URL — FIXED.** The key now travels in the `x-goog-api-key` header. Verified against Google's current Gemini API docs (ai.google.dev/gemini-api/docs, "generate content" quickstart uses `-H "x-goog-api-key: $GEMINI_API_KEY"`); the `?key=` form is the legacy pattern and leaks the key into URLs/logs. Cited in a comment in `AI/Providers.swift`.
- **(5) Chat streaming cancellation — FIXED.** The stream is now created *inside* the consuming `Task` in `ChatViewModel.send`, and every provider's producer `Task` is cancelled via `continuation.onTermination` (OpenAI-compatible client both levels, Anthropic, Gemini). Stop now ends the URLSession work instead of leaving it lingering. `cancelStreaming()` also leaves a "Stopped." message instead of an error.
- **(6) Settings instances — FIXED.** `AppSettings.shared` is the single instance, injected with `.environmentObject` in `PageMindApp`. `ChatView` and `SettingsView` use `@EnvironmentObject`; `StoreManager.shared` likewise (one StoreKit `Transaction.updates` listener instead of one per view). No view constructs `AppSettings()` or `StoreManager()` any more (verified by grep).
- **(7) Provider change resets model — FIXED.** `SettingsView` has `.onChange(of: selectedProviderRaw)` setting `selectedModel` to the new provider's `defaultModel`. `ChatView` also re-runs `viewModel.configure(with:)` when the provider or model changes in Settings.
- **(8) Collection picker — FIXED.** Library's segmented control is now a menu-style picker in the toolbar (`Menu` + inline `Picker`), showing the current collection name ("All pages" by default). Scales to many collections.
- **(11) Image/vision chat + YouTube transcripts — DONE.**
  - Vision: `AI/ImageChat.swift` (`ChatImageAttachment`, `VisionImagePrep` — downsizes to max 1024px, JPEG 0.8, max 4 per chat). `AIProvider` gained `supportsVision` + a `streamChat(..., images:)` variant (default: ignores images); OpenAI-compatible (image_url parts), Anthropic (base64 image blocks), and Gemini (inline_data parts) all implement it, attached to the last user message. ChatView has a Photo button (PhotosPicker), image chips with remove, and a warning when the current provider does not support vision. A text-only model still returns a provider error, surfaced with a hint.
  - YouTube: `Search/YouTubeTranscript.swift` — video-ID extraction (watch/shorts/embed/live/youtu.be), public `timedtext` endpoints (track list → json3, XML fallback), no API key. BrowserView shows a Transcript button on YouTube pages; the transcript is saved as a Library page for chat. No captions / restricted videos fail gracefully with a plain-language reason.
- **(12) Unit tests — DONE.** New `PageMindTests` target (see below) with 4 test files: `ReaderExtractorTests` (HTML fallback, og:title, entities, excerpt), `WebMemorySearchTests` (ranking, tags, case-insensitivity, suggestions), `WebSearchServiceTests` (`parseDuckDuckGoHTML`, redirect unwrap, 8-result cap — no network), `PendingPageImporterTests` (pure dedupe helpers + a full import round trip, skipped when the App Group suite is unavailable on the test host). `PendingPageImporter`'s dedupe logic was extracted into testable pure helpers (`filterPending`, `safariPageToImport`) and `importPendingPages` now uses them.

### Pro features — now REAL, not stubs (all gated on `StoreManager.isPro`, which stays false until real products exist)
- **Browser Agent** (`Pro/BrowserAgent.swift` + `BrowserAgentView`): plans steps for a plain-language instruction — rule-based quick plans first (scroll/click/go-to/back/reload, no model call), AI planner second (page snapshot of clickable elements → JSON steps, max 8). Approval-gated: steps are listed with checkboxes, nothing runs until Run is tapped; Stop cancels mid-run; every step is logged. Acts only in the in-app WKWebView via JS (click by text, type with proper value-setter + input/change events, scroll, navigate). Log can be saved as a chat record. BrowserView has an Agent button (paywall when not Pro) and wires its WKWebView into the agent.
- **Side-by-side compare** (`CompareView`): one prompt, two models, both streams run concurrently in a task group (plain role/content tuples + hoisted locals so the `@Sendable` closures never capture `ChatMessage` or the view), answers side by side, pick-winner saves the winning answer as a new chat.
- **Morning Brief** (`Pro/MorningBrief.swift` + `MorningBriefView`): local scheduling only — `BGTaskScheduler` BGAppRefreshTask (`com.pagemind.app.brief`, registered in `PageMindApp.init`, `UIBackgroundModes: fetch` + permitted identifiers in `Info.plist`) + local notification when ready. Time + topics + include-saved-pages settings; "Generate now" runs the same generator in the foreground; the brief is saved as a Library note. The UI says plainly that iOS may delay background tasks.
- **Deep Research** (`Pro/DeepResearch.swift` + `DeepResearchView`): search (topic + 2 variants) → fetch top 3–10 pages → on-device Reader extraction (max 5 pages, 3,000 chars each) → provider synthesises a structured Markdown report (Summary / Key points / Different viewpoints / Open questions) from those sources only, with citations. Progress text, Stop, save report to Library. Fails honestly when search returns nothing or no source is readable.
- Shared plumbing: `AI/ChatCompletion.swift` (`collectText` / `ask` — non-streaming collection over the provider stream, using Sendable role/content tuples), `Pro/ProGate.swift` (shared gate + `AgentLogEntry`), `StoreManager.shared`.

### Free polish
- **Widgets:** the main app now writes a `widgetRecentPages` snapshot (3 most recent pages) to the App Group defaults whenever the Library changes (BrowserView saves, pending-page import); widgets read the snapshot *and* the pending queue, dedupe by URL, and show an honest empty state. Still blocked on the App Group entitlement for real sync — see known issues.
- **Onboarding copy:** tightened — free web search + PDF chat on page 1, Keychain note on page 2, Web Memory on page 3.
- **Empty states:** Chat empty state now has action buttons (attach a saved page, ask with web search) and a "no API key" nudge with a Settings shortcut. Library empty states were already there.
- **Error states:** `ChatViewModel.errorHint` maps common failures to a next step (no key → add one / use OpenRouter free; 401 → check the key; 429 → wait / switch model; 404 → pick another model). ChatView shows the hint plus an "Add or check the API key in Settings" button (opens Settings in a sheet) for key/401 errors.
- **Swift 6 hardening found during read-back:** provider producer `Task`s now capture only plain `(role, content)` tuples, never `[ChatMessage]` (`@Model`, not `Sendable`); `CompareView`'s task-group closures use hoisted locals for the same reason. `PhotosPicker` change detection uses the item count, not the items themselves.

### What is still a stub / not built
- **Semantic Web Memory** (on-device embeddings, Pro v1.1 in the plan) — keyword search only, as before.
- **Custom Skills / MCP** (v1.1 in the plan) — not built, and not promised in the paywall copy beyond what exists.
- **Notion / Obsidian export** — REMOVED from the paywall 2026-11-26 (user doesn't use Notion/Obsidian). Not built, not promised. Can be added later only if users ask for it.
- **iCloud sync, macOS, hosted AI / credits** — deliberately out of v1, as planned.

### Verification done this pass (same standard as Day 1–2)
- Every changed/added file was read back in full. No duplicate type definitions within a module (`PendingSavedPage` exists twice, but in two separate targets — app and Share extension — which is pre-existing and harmless).
- Brace/paren/bracket balance checked programmatically with a Swift-aware stripper (raw strings, `"""`, comments): all files balanced. The Day 1–2 false alarm in `WebSearch.swift` is confirmed a stripper artefact, not a real imbalance.
- `project.pbxproj`: 165 objects, all keys unique, braces balanced, every referenced path exists on disk, every source file on disk is referenced. New files added: 8 app sources + 4 test files + test target. New shared scheme `PageMind.xcodeproj/xcshareddata/xcschemes/PageMind.xcscheme` (Build + Test actions) parses as XML.
- Both CI workflows parse as YAML; `build.yml` gained a `xcodebuild test` step (iOS Simulator, iPhone 17, no signing).
- No "SurfMind" string in any source file. (This file and `~/workspace/pagemind-plan.md` mention the competitor by name in prose — plan/comparison context, not app code or branding.) No API-key pattern (`sk-…`) in code. No leftover stub text ("coming in the Day 11-13", "not wired yet", etc.).

### What was NOT verified — do not claim otherwise
- **Still not compiled.** No Swift/Xcode on this Linux VM. The first real compile is still the GitHub runner after the repo is created. New likeliest-first-build issues: (a) `BGTaskScheduler` / `BackgroundTasks` import in the app target, (b) the `xcodebuild test` step's simulator name (`iPhone 17`) on the runner image, (c) `ModelContainer(for: SavedPage.self, ...)` in the test round trip, (d) any remaining Swift 6 isolation issue in the new Pro views.
- **Nothing has run on a device or simulator.** In particular, untested on device: the Browser Agent JS against real pages, the AI planner's JSON parsing, YouTube `timedtext` against real videos (the endpoint is best-effort and YouTube can change it), the Morning Brief background task delivery (iOS may defer it), the widget snapshot round trip, and the unit tests themselves (they run first on the runner).
- **No App Store review exposure yet.** Same Guideline 4.2/4.3 risk as before.

## What was built

46 files in `~/workspace/pagemind/` (see file list below): a hand-written Xcode 16 project with 4 targets (app, Share Extension, Safari Web Extension, WidgetKit), the full SwiftUI app (Browser + Reader, Chat with 7 provider kinds, web search with citations, PDF chat, Library / Web Memory, Settings + Keychain, onboarding, StoreKit 2 + paywall), both extensions, widgets, unsigned-.ipa CI, README, privacy policy, and this file.

## What WAS verified on this VM (Linux, no Xcode, no Swift toolchain)

- Every Swift file (26 files, ~3,700 lines) was written and then **read back in full** by the coordinator. No duplicate type definitions. Brace/paren/bracket balance checked programmatically for every file (one false alarm in WebSearch.swift — a regex literal containing braces — confirmed fine by reading it).
- Cross-builder seams checked against the real files: `AppSettings.providerConfig` (property, not method), `ModelCatalog.fetchOpenRouterModels()` (non-throwing), `HighlightPresets.prompt(for:text:)`, `SavedPage.collectionID` (UUID?, no relationship), `ChatViewModel.configure(with:)`, `KeychainStore` key IDs.
- All 4 Info.plists + `PrivacyInfo.xcprivacy` parse with `plistlib`. `manifest.json` + all 3 asset-catalog `Contents.json` files parse as JSON. `content.js`, `background.js`, `popup.js` pass `node --check`.
- Both CI workflows parse as valid YAML.
- `project.pbxproj`: 131 objects, all IDs unique, braces balanced, all 41 referenced paths exist on disk, every source/resource file on disk is referenced (except the `Contents.json` files inside `.xcassets`, which Xcode reads via the catalog itself).
- No "SurfMind" string anywhere in the repo. No API key pattern (`sk-…`) anywhere in code.

## What was NOT verified — do not claim otherwise

- **It has not compiled.** There is no Swift/Xcode on this Linux VM. The first real compile happens on the GitHub runner after the repo is created (see Next step). Expect the first runner build to surface a handful of Swift 6 strict-concurrency or API-shape issues; the likeliest spots are listed under Known risks.
- **Nothing has run on a device or simulator.** In particular, untested on device: the Share Extension → App Group queue → main-app import round trip, the Safari Web Extension native↔JS bridge, StoreKit sandbox purchases, widgets, and the WKWebView Reader extraction on real pages.
- **No App Store review exposure yet.** Guideline 4.2/4.3 (thin-wrapper AI apps) is the main review risk; the native browser, Reader, Web Memory, and PDF features are the mitigation, and the listing must show them.

## Known issues / gaps — updated after the Day 8–13 pass

Still open (need Developer / App Store Connect / device testing — deliberately left alone this pass):
1. **No signing, no entitlements file (deliberate).** `CODE_SIGNING_ALLOWED=NO` everywhere. App Groups (`group.com.pagemind.app`) are referenced in code but not provisioned: the SwiftData container falls back to an in-memory store (pages won't persist) and the extension queues won't reach the app until the App Group capability + entitlements are added — that happens when Apple Developer is bought. This also blocks real widget sync (the snapshot writer is a no-op until the group exists).
2. **App Icon is an empty set.** `AppIcon.appiconset` has no images; the app builds and installs with a blank icon. A real icon must be added before any App Store submission.
3. **StoreKit products don't exist yet.** `StoreManager.loadProducts()` returns nothing until `pagemind.pro.monthly` / `pagemind.pro.lifetime` are created in App Store Connect. Until then `isPro` is always false and the paywall says so. Nothing fakes a purchase.
10. **Safari extension `manifest.json` background is `"type": "module"`** with `background.js` using `browser.*` APIs; Safari's MV3 background handling differs from Chrome's and needs on-device verification.

Fixed in the Day 8–13 pass (see the section above for detail):
4. ~~Gemini key in URL query~~ — now `x-goog-api-key` header.
5. ~~Chat streaming cancellation~~ — stream created inside the consuming task, producer tasks cancelled via `onTermination`.
6. ~~Per-view settings instances~~ — `AppSettings.shared` / `StoreManager.shared`.
7. ~~Provider change doesn't reset model~~ — resets to the new provider's default.
8. ~~Segmented collection picker~~ — menu-style picker.
9. ~~Widgets read the pending queue only~~ — now read the app's snapshot + the queue, deduped. Still blocked on the App Group entitlement for real sync (see item 1).
11. ~~No image/vision chat UI, no YouTube transcripts~~ — both built.
12. ~~No unit tests~~ — `PageMindTests` target with 4 test files + CI test step.

New known limitations from this pass:
13. **Notion / Obsidian export — REMOVED from the paywall 2026-11-26** (user doesn't use Notion/Obsidian; see "What is still a stub" above). Not built, not promised. The paywall code (`PageMind/Pro/PaywallView.swift`) no longer lists it — verified by grep 2026-11-26. Earlier drafts of this file that said it was "listed but not implemented" were stale.
14. **Deep Research view cancellation is not fully wired through:** the Stop button cancels the engine's run task, but if the view's own `Task` is cancelled (e.g. the view disappears) the engine task keeps running until it finishes or `cancel()` is called. The engine task is unstructured, not a child of the view's task.
15. **YouTube `timedtext` is best-effort and undocumented.** It works for public videos with captions today; YouTube can change or block it at any time, and it fails (gracefully) for videos without captions.
16. **Morning Brief background delivery is at iOS's discretion.** The task is registered and scheduled, but iOS may delay or skip it; "Generate now" is the reliable path.
17. **Browser Agent AI planner depends on the model returning clean JSON.** `parsePlanJSON` tolerates surrounding prose/code fences, but a model that returns malformed JSON yields no steps and an error message. The rule-based planner covers the common instructions without a model call.
18. **Paywall lists "Unlimited semantic Web Memory" but only keyword search is built.** `PageMind/Data/WebMemorySearch.swift` is keyword + recency; on-device embeddings are v1.1 and not built. Decide before submission: remove that line from `PaywallView.swift` (same as the Notion/Obsidian removal 2026-11-26) or build semantic search. Do not ship the paywall promising it as-is.

## Coordinator fixes applied after the two builders finished

- Added `PageMind/Data/PendingPageImporter.swift` and wired it into `MainTabView` (`.task` on launch) — the builders had flagged that nothing imported the Share/Safari queues.
- Added `PageMindSafari/popup.html`, `popup.js`, `background.js` (manifest referenced `popup.html`/`background.js`, which didn't exist) and extended `content.js` to handle `savePage` / `extractPage` messages from the popup.
- Added `PageMind/Info.plist` (URL scheme `pagemind://`, `NSAllowsLocalNetworking` for local Ollama) and a minimal `Assets.xcassets`.
- Added PDF attach UI to `ChatView` (file importer, 10-PDF cap, chips with remove) — the PDF extractor existed but had no UI to reach it.
- Fixed a stale comment in `SafariWebExtensionHandler.swift`.

## File list (59) — current after the Day 8–13 pass

```
.github/workflows/build.yml
.github/workflows/ipa.yml
.gitignore
PRIVACY.md
README.md
BUILD-NOTES.md (this file)
PageMind.xcodeproj/project.pbxproj
PageMind.xcodeproj/xcshareddata/xcschemes/PageMind.xcscheme
PageMind/Info.plist
PageMind/PrivacyInfo.xcprivacy
PageMind/Assets.xcassets/Contents.json
PageMind/Assets.xcassets/AppIcon.appiconset/Contents.json
PageMind/Assets.xcassets/AccentColor.colorset/Contents.json
PageMind/PageMindApp.swift
PageMind/Models.swift
PageMind/AI/AIProvider.swift
PageMind/AI/ChatCompletion.swift          (NEW Day 8–13)
PageMind/AI/ChatViewModel.swift
PageMind/AI/ImageChat.swift               (NEW Day 8–13)
PageMind/AI/ModelCatalog.swift
PageMind/AI/OpenAICompatibleClient.swift
PageMind/AI/Providers.swift
PageMind/Data/AppSettings.swift
PageMind/Data/KeychainStore.swift
PageMind/Data/PendingPageImporter.swift
PageMind/Data/WebMemorySearch.swift
PageMind/Data/WidgetDataWriter.swift      (NEW Day 8–13)
PageMind/PDF/PDFChat.swift
PageMind/Reader/ReaderExtractor.swift
PageMind/Search/WebSearch.swift
PageMind/Search/YouTubeTranscript.swift   (NEW Day 8–13)
PageMind/Pro/BrowserAgent.swift           (NEW Day 8–13)
PageMind/Pro/DeepResearch.swift           (NEW Day 8–13)
PageMind/Pro/MorningBrief.swift           (NEW Day 8–13)
PageMind/Pro/ProGate.swift                (NEW Day 8–13)
PageMind/Pro/StoreManager.swift
PageMind/Pro/PaywallView.swift
PageMind/Pro/ProFeatures.swift
PageMind/Views/BrowserView.swift
PageMind/Views/ChatView.swift
PageMind/Views/HighlightToolbar.swift
PageMind/Views/LibraryView.swift
PageMind/Views/OnboardingView.swift
PageMind/Views/SettingsView.swift
PageMindShare/ShareViewController.swift
PageMindShare/Info.plist
PageMindSafari/SafariWebExtensionHandler.swift
PageMindSafari/Info.plist
PageMindSafari/manifest.json
PageMindSafari/content.js
PageMindSafari/background.js
PageMindSafari/popup.html
PageMindSafari/popup.js
PageMindWidgets/PageMindWidgets.swift
PageMindWidgets/Info.plist
PageMindTests/ReaderExtractorTests.swift  (NEW Day 8–13)
PageMindTests/WebMemorySearchTests.swift  (NEW Day 8–13)
PageMindTests/WebSearchServiceTests.swift (NEW Day 8–13)
PageMindTests/PendingPageImporterTests.swift (NEW Day 8–13)
```

## Next step — for the user

1. **Create an empty private repo on GitHub named `PageMind-iOS`.** Do not add a README, .gitignore, or license in the GitHub UI (the repo already has those files — an initialised repo would conflict on push).
2. Tell Muse the repo is created. Muse will push this tree, and the first GitHub runner build (`build.yml`) will tell us whether it actually compiles.
3. Then run the `ipa.yml` workflow, download the unsigned `.ipa`, re-sign it with your sideload tool, and test on your phone: save a page from Safari, ask about it, try an OpenRouter free model.

## After the first green build (Day 14–16, not this run)

Day 8–13 items are done (vision chat, YouTube transcripts, unit tests, real Pro features). Still to do after the first compile: voice input + read-aloud, App Shortcuts, real App Icon, semantic Web Memory, Custom Skills/MCP. The Morning Brief and Safari MV3 background both need on-device verification.
