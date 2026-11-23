// Can Apple's on-device model run here? Prints the availability and, when it is available,
// answers one synthetic question (no session data) so the whole path is proven.
//
//     d=$(mktemp -d) && swiftc -parse-as-library -O tools/progress-eval/ondevice-check.swift -o "$d/check" && "$d/check"

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
struct Check {
    static func main() async {
        let info = ProcessInfo.processInfo
        print("macOS \(info.operatingSystemVersionString)")
        #if arch(arm64)
        print("arch arm64")
        #else
        print("arch not arm64: the on-device model needs Apple silicon")
        #endif
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            print("UNAVAILABLE: needs macOS 26 or later")
            exit(2)
        }
        await probe()
        #else
        print("UNAVAILABLE: this SDK has no FoundationModels framework")
        exit(2)
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct Estimate {
    @Guide(description: "bounded if the request has a recognisable finish line, open_ended otherwise")
    var kind: String
    @Guide(description: "how far along the objective is, in tenths", .range(0...10))
    var tenths: Int
}

@available(macOS 26, *)
func probe() async {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
        print("AVAILABLE")
    case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible:
            print("UNAVAILABLE: deviceNotEligible (this Mac cannot run Apple Intelligence)")
        case .appleIntelligenceNotEnabled:
            print("UNAVAILABLE: appleIntelligenceNotEnabled (turn on Apple Intelligence in System Settings > Apple Intelligence & Siri)")
        case .modelNotReady:
            print("UNAVAILABLE: modelNotReady (Apple Intelligence is on but the model is still downloading or preparing)")
        @unknown default:
            print("UNAVAILABLE: \(reason)")
        }
        exit(1)
    }
    let session = LanguageModelSession(instructions: "You estimate how far along a coding objective is.")
    let prompt = """
    Synthetic test, not a real session. Request: "Add a dark mode toggle to the settings page." \
    Approved plan headings: 1. Add theme tokens 2. Toggle component 3. Persist choice 4. Tests. \
    Recent actions: edit theme.css; edit Toggle.tsx; check npm test -> pass. \
    Claude last said: "Tokens and the toggle are in; next I will persist the choice."
    """
    let started = Date()
    do {
        let answer = try await session.respond(to: prompt, generating: Estimate.self)
        print("ANSWER kind=\(answer.content.kind) tenths=\(answer.content.tenths) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        print("context size \(model.contextSize) tokens")
    } catch {
        print("FAILED: \(error)")
        exit(3)
    }
}
#endif
