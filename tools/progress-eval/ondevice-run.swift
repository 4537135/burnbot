// Stage A candidate: Apple's on-device model, asked exactly what Haiku is asked.
// candidates.py ondevice-prep writes the instructions and one prompt per checkpoint; this
// answers each in a fresh session with guided generation (the same fields as candidates.py's
// SCHEMA) and greedy sampling, and appends one JSON line per answer. Finished ids are skipped
// on a rerun. It holds no session data itself.
//
//     d=$(mktemp -d) && swiftc -parse-as-library -O tools/progress-eval/ondevice-run.swift -o "$d/run" \
//       && "$d/run" DIR/candidates/ondevice

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
struct Run {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 2 else {
            print("usage: run DIR/candidates/ondevice")
            exit(64)
        }
        #if canImport(FoundationModels) && arch(arm64)
        guard #available(macOS 26, *) else {
            print("UNAVAILABLE: needs macOS 26 or later")
            exit(2)
        }
        await answerAll(folder: args[1])
        #else
        print("UNAVAILABLE: needs Apple silicon and an SDK with FoundationModels")
        exit(2)
        #endif
    }
}

#if canImport(FoundationModels) && arch(arm64)
@available(macOS 26, *)
@Generable
struct Estimate {
    @Guide(description: "bounded if the request has a recognisable finish line, open_ended if it has none", .anyOf(["bounded", "open_ended"]))
    var kind: String
    @Guide(description: "how much of the whole job is done, by milestones reached; 0 for open_ended work", .range(0...10))
    var tenths: Int
    @Guide(description: "work sections in the approved plan, 0 when there is no plan", .range(0...20))
    var plan_sections: Int
    @Guide(description: "plan work sections fully done, 0 when there is no plan", .range(0...20))
    var plan_done: Int
    @Guide(description: "true only if the work is finished and checked")
    var complete: Bool
    @Guide(description: "how sure you are that tenths is right to within one tenth", .range(0.0...1.0))
    var confidence: Double
    @Guide(description: "up to 24 characters saying where the work is")
    var label: String
}

struct Line: Decodable { let id: String; let prompt: String }

@available(macOS 26, *)
func answerAll(folder: String) async {
    let model = SystemLanguageModel.default
    if case .unavailable(let reason) = model.availability {
        print("UNAVAILABLE: \(reason)")
        exit(1)
    }
    let base = URL(fileURLWithPath: folder)
    guard let instructions = try? String(contentsOf: base.appendingPathComponent("instructions.txt"), encoding: .utf8),
          let prompts = try? String(contentsOf: base.appendingPathComponent("prompts.jsonl"), encoding: .utf8) else {
        print("missing instructions.txt / prompts.jsonl in \(folder); run candidates.py ondevice-prep first")
        exit(66)
    }
    let outURL = base.appendingPathComponent("answers.jsonl")
    var done = Set<String>()
    if let old = try? String(contentsOf: outURL, encoding: .utf8) {
        for line in old.split(separator: "\n") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let id = obj["id"] as? String, obj["error"] == nil { done.insert(id) }
        }
    }
    if !FileManager.default.fileExists(atPath: outURL.path) {
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
    }
    guard let out = try? FileHandle(forWritingTo: outURL) else { print("cannot write \(outURL.path)"); exit(73) }
    out.seekToEndOfFile()
    print("context size \(model.contextSize) tokens")
    let items = prompts.split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
    for item in items where !done.contains(item.id) {
        var row: [String: Any] = ["id": item.id]
        let started = Date()
        do {
            let session = LanguageModelSession(instructions: instructions)
            let answer = try await session.respond(to: item.prompt, generating: Estimate.self,
                                                   options: GenerationOptions(samplingMode: .greedy))
            let e = answer.content
            row["structured_output"] = ["kind": e.kind, "tenths": e.tenths, "plan_sections": e.plan_sections,
                                        "plan_done": e.plan_done, "complete": e.complete,
                                        "confidence": e.confidence, "label": String(e.label.prefix(24))]
        } catch {
            row["error"] = String(describing: error)
        }
        row["_seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            out.write(data)
            out.write(Data("\n".utf8))
        }
        print(item.id, row["error"] == nil ? "ok" : "ERROR", row["_seconds"] ?? 0)
    }
    try? out.close()
}
#endif
