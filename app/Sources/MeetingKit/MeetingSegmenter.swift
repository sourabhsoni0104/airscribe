import Foundation

struct MeetingTranscriptionResult: Sendable {
    let text: String
    let timings: [TranscribedWordTiming]
    let duration: TimeInterval?

    static let empty = MeetingTranscriptionResult(text: "", timings: [], duration: nil)
}

enum MeetingSegmenter {
    static func segments(
        text: String,
        speaker: MeetingSpeaker,
        timings: [TranscribedWordTiming],
        duration: TimeInterval
    ) -> [MeetingTranscriptSegment] {
        let chunks = textChunks(text)
        guard !chunks.isEmpty else { return [] }
        let wordCounts = chunks.map(wordCount)
        let totalWords = max(wordCounts.reduce(0, +), 1)
        let effectiveDuration = max(duration, timings.last?.endTime ?? 0, 0.1)
        var consumedWords = 0

        return chunks.enumerated().map { index, chunk in
            let startWord = consumedWords
            consumedWords += wordCounts[index]
            let endWord = consumedWords
            let startTime: TimeInterval
            let endTime: TimeInterval

            if !timings.isEmpty {
                let startIndex = min(
                    Int((Double(startWord) / Double(totalWords)) * Double(timings.count)),
                    timings.count - 1
                )
                let endIndex = min(
                    max(Int(ceil((Double(endWord) / Double(totalWords)) * Double(timings.count))) - 1, startIndex),
                    timings.count - 1
                )
                startTime = max(timings[startIndex].startTime, 0)
                endTime = max(timings[endIndex].endTime, startTime + 0.05)
            } else {
                startTime = effectiveDuration * Double(startWord) / Double(totalWords)
                endTime = max(
                    effectiveDuration * Double(endWord) / Double(totalWords),
                    startTime + 0.05
                )
            }

            return MeetingTranscriptSegment(
                speaker: speaker,
                startTime: startTime,
                endTime: endTime,
                text: chunk
            )
        }
    }

    private static func textChunks(_ text: String, maximumWords: Int = 24) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var chunks: [String] = []
        var current: [String] = []

        for word in words {
            current.append(word)
            let endsSentence = word.last.map { ".!?。！？".contains($0) } ?? false
            if endsSentence || current.count >= maximumWords {
                chunks.append(current.joined(separator: " "))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
        return chunks
    }

    private static func wordCount(_ text: String) -> Int {
        max(text.split(whereSeparator: \.isWhitespace).count, 1)
    }
}
