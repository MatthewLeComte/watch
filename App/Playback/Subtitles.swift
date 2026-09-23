import Foundation

struct Cue: Sendable {
    var start: Double
    var end: Double
    var text: String
}

func parseVTT(_ raw: String) -> [Cue] {
    let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var cues: [Cue] = []
    for block in text.components(separatedBy: "\n\n") {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let timeLine = lines.first(where: { $0.contains("-->") }) else { continue }
        let parts = timeLine.split(separator: " ")
        guard parts.count >= 3,
              let start = parseStamp(String(parts[0])),
              let end = parseStamp(String(parts[2]))
        else { continue }
        let body = lines.drop { !$0.contains("-->") }.dropFirst().joined(separator: "\n")
        let plain = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cues.append(Cue(start: start, end: end, text: plain.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }
    return cues
}

private func parseStamp(_ raw: String) -> Double? {
    let stamp = raw.split(separator: " ").first.map(String.init) ?? raw
    let bits = stamp.split(separator: ":")
    let secondsPart = bits.last?.split(separator: ".") ?? []
    guard let sec = secondsPart.first.flatMap({ Double($0) }) else { return nil }
    let ms = secondsPart.count > 1 ? Double("0.\(secondsPart[1])") ?? 0 : 0
    if bits.count == 3, let h = Double(bits[0]), let m = Double(bits[1]) {
        return h * 3600 + m * 60 + sec + ms
    }
    if bits.count == 2, let m = Double(bits[0]) {
        return m * 60 + sec + ms
    }
    return nil
}

func cue(at time: Double, in cues: [Cue]) -> String? {
    cues.first { time >= $0.start && time < $0.end }?.text
}
