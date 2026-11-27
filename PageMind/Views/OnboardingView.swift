import SwiftUI

/// Three-page onboarding shown on first launch, in the same charcoal
/// look as the rest of the app.
struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            OnboardingPage(
                systemImage: "book.pages",
                title: "PageMind reads with you",
                bodyText: "Open any web page, PDF or YouTube video, then ask anything about it. PageMind answers from what's in front of you, with sources."
            )
            .tag(0)

            OnboardingPage(
                systemImage: "key",
                title: "Free models, or your own key",
                bodyText: "Start with free AI models from OpenRouter: a free account and key take about two minutes. Or add your own key for OpenAI, Anthropic, Gemini, Groq or a local Ollama server. Keys stay in the iOS Keychain on this phone."
            )
            .tag(1)

            OnboardingPage(
                systemImage: "lock.shield",
                title: "Private by design",
                bodyText: "Pages you save stay on your phone and stay searchable. PageMind has no server of its own and no account to sign up for."
            )
            .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(PageMindDesign.appBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    hasSeenOnboarding = true
                }
            } label: {
                Text(page == 2 ? "Get started" : "Continue")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(PageMindDesign.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }
}

private struct OnboardingPage: View {
    let systemImage: String
    let title: String
    let bodyText: String

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(PageMindDesign.brandGradient)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text(title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            Text(bodyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Spacer()
            Spacer()
        }
        .padding()
    }
}
