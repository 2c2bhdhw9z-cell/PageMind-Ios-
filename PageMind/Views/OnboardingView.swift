import SwiftUI

/// Three-page onboarding shown on first launch.
struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            OnboardingPage(
                systemImage: "book.pages",
                title: "PageMind reads with you",
                bodyText: "Save any page, PDF or YouTube video, then ask anything about it. PageMind answers from the page in front of you — with sources. Web search and PDF chat are free."
            )
            .tag(0)

            OnboardingPage(
                systemImage: "key.fill",
                title: "Use free models or bring your own key",
                bodyText: "Start with free models on OpenRouter — no account needed. Or add your own key for OpenAI, Anthropic, Gemini, Groq or a local Ollama server. Your key stays in the iOS Keychain on this device."
            )
            .tag(1)

            OnboardingPage(
                systemImage: "lock.shield",
                title: "Private by design",
                bodyText: "Your saved pages stay on your device and stay searchable — that is Web Memory. PageMind has no server of its own, no account to sign up for, and nothing to sell you except Pro features."
            )
            .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .safeAreaInset(edge: .bottom) {
            Button(page == 2 ? "Get started" : "Continue") {
                if page < 2 {
                    page += 1
                } else {
                    hasSeenOnboarding = true
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

private struct OnboardingPage: View {
    let systemImage: String
    let title: String
    let bodyText: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 72))
                .foregroundStyle(.accent)
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(bodyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .padding()
    }
}
