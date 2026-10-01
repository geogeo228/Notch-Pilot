import Foundation

/// Live usage percentages pulled from Anthropic's oauth/usage endpoint
/// — the same data Claude's account settings page shows you.
///
/// Each window carries a 0-100 utilization percentage and an optional
/// reset timestamp. Nil windows mean "not applicable for this plan"
/// (e.g. `sevenDayOpus` is null for plans without Opus access).
struct ClaudeUsage: Equatable {
    struct Window: Equatable {
        let utilization: Double    // 0…100
        let resetsAt: Date?
    }

    struct ExtraUsage: Equatable {
        let isEnabled: Bool
        let monthlyLimit: Int
        let usedCredits: Double
        let utilization: Double
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDaySonnet: Window?
    let sevenDayOpus: Window?
    let extraUsage: ExtraUsage?
    let fetchedAt: Date
}

/// Outcome of a single usage-endpoint hit. The aggregator uses
/// `.rateLimited(retryAfter:)` to back off so we don't keep
/// hammering the endpoint while Anthropic is throttling us.
enum UsageFetchOutcome {
    case success(ClaudeUsage)
    case rateLimited(retryAfter: TimeInterval)
    case failed
}

/// Georgi fork: no network, no Keychain. The upstream version read the
/// Claude Code OAuth token from the Keychain and called Anthropic's
/// oauth/usage endpoint. Here it always reports `.failed`, so the
/// aggregator falls back to local jsonl-derived data.
enum UsageAPI {
    static func fetchUsage() async -> UsageFetchOutcome { .failed }
}
