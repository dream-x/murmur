import XCTest
@testable import murmur

final class SpeechDetectorTests: XCTestCase {
    private let rate = 16_000.0

    private func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.0005, count: Int(seconds * rate))
    }

    func testFindsSeparatedPhrases() {
        let audio = silence(1) + tone(1.5) + silence(2) + tone(1) + silence(1)
        let ranges = SpeechDetector.segments(audio, sampleRate: rate)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Double(ranges[0].lowerBound) / rate, 0.75, accuracy: 0.1)
        XCTAssertEqual(Double(ranges[1].lowerBound) / rate, 4.25, accuracy: 0.1)
    }

    func testShortPauseKeepsOnePhrase() {
        let audio = silence(1) + tone(1) + silence(0.4) + tone(1) + silence(1)
        XCTAssertEqual(SpeechDetector.segments(audio, sampleRate: rate).count, 1)
    }

    func testSilenceAndTinyInputs() {
        XCTAssertTrue(SpeechDetector.segments(silence(5), sampleRate: rate).isEmpty)
        XCTAssertTrue(SpeechDetector.segments([], sampleRate: rate).isEmpty)
        XCTAssertTrue(SpeechDetector.segments([0.1, 0.2], sampleRate: rate).isEmpty)
    }

    func testLongMonologueIsSplit() {
        let audio = tone(70)
        let ranges = SpeechDetector.segments(audio, sampleRate: rate)
        XCTAssertGreaterThanOrEqual(ranges.count, 3)
        for r in ranges {
            XCTAssertLessThanOrEqual(Double(r.count) / rate, 31)
            XCTAssertLessThanOrEqual(r.upperBound, audio.count)
        }
    }

    func testRangesStayInBoundsWithSpeechAtEdges() {
        let audio = tone(1) + silence(2) + tone(1)
        for r in SpeechDetector.segments(audio, sampleRate: rate) {
            XCTAssertGreaterThanOrEqual(r.lowerBound, 0)
            XCTAssertLessThanOrEqual(r.upperBound, audio.count)
        }
    }
}

final class TranscriptTests: XCTestCase {
    private func seg(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    func testEchoOfRemoteSpeechIsRemovedFromMic() {
        let segments = [
            seg("Собеседники", 1, 5, "Давайте обсудим план релиза на следующую неделю."),
            seg("Я", 1.2, 5.1, "Давайте обсудим план релиза на следующую неделю"),
            seg("Я", 7, 9, "Я подготовлю презентацию к пятнице."),
        ]
        let result = TranscriptionPipeline.removeEcho(segments)
        XCTAssertEqual(result.map(\.speaker), ["Собеседники", "Я"])
        XCTAssertEqual(result.last?.text, "Я подготовлю презентацию к пятнице.")
    }

    func testSameWordsAtDifferentTimeAreKept() {
        let segments = [
            seg("Собеседники", 1, 3, "Согласен, давайте так и сделаем."),
            seg("Я", 20, 22, "Согласен, давайте так и сделаем."),
        ]
        XCTAssertEqual(TranscriptionPipeline.removeEcho(segments).count, 2)
    }

    func testMarkdownMergesConsecutivePhrasesOfSameSpeaker() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let md = TranscriptionPipeline.markdown([
            seg("Я", 0, 2, "Привет."),
            seg("Я", 3, 5, "Начнём?"),
            seg("Собеседники", 6, 8, "Да."),
            seg("Я", 3700, 3702, "Пока."),
        ], folder: folder)

        XCTAssertTrue(md.contains("**[00:00:00] Я:** Привет. Начнём?"))
        XCTAssertTrue(md.contains("**[00:00:06] Собеседники:** Да."))
        XCTAssertTrue(md.contains("**[01:01:40] Я:** Пока."))
    }

    func testWavHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try TranscriptionPipeline.writeWav([0, 1, -1, 2], to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        let samples = data[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples, [0, 32767, -32767, 32767]) // clipped
    }
}
