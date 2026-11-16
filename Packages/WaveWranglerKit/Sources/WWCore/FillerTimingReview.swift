import Foundation

/// A bounded, canonical whole-word vocabulary. Empty explicitly disables automatic suggestions.
public struct FillerWords: Sendable, Equatable, Codable {
    public let words: [String]

    public static let defaults = Self(canonicalWords: ["er", "erm", "uh", "um"])

    private init(canonicalWords: [String]) { words = canonicalWords }

    private enum CodingKeys: String, CodingKey { case words }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        words = try container.decode([String].self, forKey: .words)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .words, in: container,
                debugDescription: "Filler words must be a sorted unique list of up to 128 normalized single words.")
        }
    }

    public init(_ words: [String]) throws(DomainError) {
        let canonical = Array(Set(words.map(Self.normalized))).sorted()
        self.init(canonicalWords: canonical)
        guard isValid else { throw .invalidFillerWords }
    }

    public init(text: String) throws(DomainError) {
        guard text.utf8.count <= 16_384 else { throw .invalidFillerWords }
        try self.init(text.components(separatedBy: .newlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    public var isValid: Bool {
        words.count <= 128 && words == Array(Set(words)).sorted()
            && words.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 64 && $0 == Self.normalized($0)
                    && $0.unicodeScalars.allSatisfy { CharacterSet.letters.union(.nonBaseCharacters).contains($0) }
            }
    }

    public func contains(_ text: String) -> Bool { words.contains(Self.normalized(text)) }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased(with: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
}

extension ShowDocumentModel {
    public func fillerWords(for speaker: SpeakerID, appDefaults: FillerWords) -> FillerWords {
        self.speaker(speaker)?.fillerWords ?? show.fillerWords ?? appDefaults
    }

    public func settingFillerWords(_ words: FillerWords?, for speaker: SpeakerID? = nil) throws(DomainError) -> Self {
        guard schemaVersion == SchemaVersion.show, words?.isValid != false else { throw .invalidFillerWords }
        var result = self
        if let speaker {
            guard let index = speakers.firstIndex(where: { $0.id == speaker }) else { throw .speakerNotFound(speaker) }
            result.speakers[index].fillerWords = words
        } else {
            result.show.fillerWords = words
        }
        return result
    }
}

/// Audible-word timing for human review, never an editorial cut interval.
public struct FillerTimingBounds: Sendable, Equatable, Codable {
    public let sourceStartFrame: Int64
    public let sourceEndFrame: Int64
    public let alignedStart: Double
    public let alignedEnd: Double

    public init(sourceStartFrame: Int64, sourceEndFrame: Int64, alignedStart: Double, alignedEnd: Double) {
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.alignedStart = alignedStart
        self.alignedEnd = alignedEnd
    }

    public init?(word: TranscriptWord) {
        guard word.isValid, let a = word.sourceStartFrame, let b = word.sourceEndFrame,
              let start = word.alignedStart, let end = word.alignedEnd else { return nil }
        self.init(sourceStartFrame: a, sourceEndFrame: b, alignedStart: start, alignedEnd: end)
    }

    public var isValid: Bool {
        sourceStartFrame >= 0 && sourceEndFrame > sourceStartFrame && sourceEndFrame <= 192_000 * 86_400
            && alignedStart.isFinite && alignedEnd.isFinite
            && abs(alignedStart) <= 86_400 && abs(alignedEnd) <= 86_400 && alignedEnd > alignedStart
    }
}

public enum FillerReviewOrigin: String, Sendable, Codable { case detected, manual }
public enum FillerReviewDecision: String, Sendable, Codable { case pending, reviewed, rejected }

/// Captured origins remain immutable even after the live transcript, source or accepted map is replaced.
/// Human judgments are reference data, not phonetic ground truth or cut authorization.
public struct FillerTimingReview: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let origin: FillerReviewOrigin
    public let speaker: SpeakerID
    public let primary: ChannelReference
    public let sourceRate: Int
    public let sourceIdentity: String
    public let alignmentRevision: Int
    public let transcriptID: UUID?
    public let word: TranscriptWord?
    public let modelRecipe: String?
    public let analyzedRange: EpisodeWorkingRange?
    public let detectorRecipe: String?
    public let detectorWords: FillerWords?
    public let initialBounds: FillerTimingBounds
    public let detectedBounds: FillerTimingBounds?
    public var humanBounds: FillerTimingBounds?
    public var decision: FillerReviewDecision

    public init(id: UUID = UUID(), origin: FillerReviewOrigin, speaker: SpeakerID,
                primary: ChannelReference, sourceRate: Int, sourceIdentity: String, alignmentRevision: Int,
                transcriptID: UUID? = nil, word: TranscriptWord? = nil, modelRecipe: String? = nil,
                analyzedRange: EpisodeWorkingRange? = nil, detectorRecipe: String? = nil, detectorWords: FillerWords? = nil,
                initialBounds: FillerTimingBounds, detectedBounds: FillerTimingBounds? = nil,
                humanBounds: FillerTimingBounds? = nil, decision: FillerReviewDecision = .pending) {
        self.id = id
        self.origin = origin
        self.speaker = speaker
        self.primary = primary
        self.sourceRate = sourceRate
        self.sourceIdentity = sourceIdentity
        self.alignmentRevision = alignmentRevision
        self.transcriptID = transcriptID
        self.word = word
        self.modelRecipe = modelRecipe
        self.analyzedRange = analyzedRange
        self.detectorRecipe = detectorRecipe
        self.detectorWords = detectorWords
        self.initialBounds = initialBounds
        self.detectedBounds = detectedBounds
        self.humanBounds = humanBounds
        self.decision = decision
    }

    public var bounds: FillerTimingBounds { humanBounds ?? initialBounds }
    public var isAdjusted: Bool { humanBounds.map { $0 != initialBounds } ?? false }
    public var retainsUserJudgment: Bool {
        origin == .manual || decision != .pending || humanBounds != nil
    }

    /// Suppression identifies a source event, not a new transcript-word association.
    public func coversSameEvent(as other: Self) -> Bool {
        speaker == other.speaker && primary == other.primary && sourceRate == other.sourceRate
            && sourceIdentity == other.sourceIdentity && alignmentRevision == other.alignmentRevision
            && (Self.overlaps(initialBounds, other.initialBounds) || Self.overlaps(bounds, other.initialBounds))
    }

    private static func overlaps(_ a: FillerTimingBounds, _ b: FillerTimingBounds) -> Bool {
        a.sourceStartFrame < b.sourceEndFrame && b.sourceStartFrame < a.sourceEndFrame
    }
    public var status: String {
        if decision == .rejected { return "Not a filler" }
        if decision == .pending { return origin == .manual ? "Manual · pending" : "Pending" }
        if origin == .manual { return "Manual · reviewed" }
        return isAdjusted ? "Adjusted" : "Reviewed unchanged"
    }

    public var isValid: Bool {
        guard (8000...192000).contains(sourceRate), alignmentRevision > 0,
              primary.channel.value.map({ $0 >= 0 }) == true,
              sourceIdentity.count == 64, sourceIdentity.allSatisfy(\.isHexDigit),
              initialBounds.isValid, humanBounds?.isValid != false,
              word?.isValid != false, analyzedRange?.isValid != false,
              analyzedRange.map({ $0.alignmentRevision == alignmentRevision }) != false,
              modelRecipe.map({ !$0.isEmpty && $0.utf8.count <= 256 }) != false,
              (transcriptID == nil) == (modelRecipe == nil),
              word == nil || transcriptID != nil else { return false }
        switch origin {
        case .detected:
            let recognized: Bool
            if detectorRecipe == Self.detectorVersion, detectorWords == nil {
                recognized = Self.isHesitation(word?.text ?? "")
            } else if detectorRecipe == Self.configuredDetectorVersion, let detectorWords, detectorWords.isValid {
                recognized = detectorWords.contains(word?.text ?? "")
            } else {
                recognized = false
            }
            return transcriptID != nil && recognized
                && word.flatMap(FillerTimingBounds.init(word:)) == detectedBounds
                && detectedBounds == initialBounds
        case .manual:
            return detectedBounds == nil && detectorRecipe == nil && detectorWords == nil
        }
    }

    public mutating func revertToDetected() {
        guard let detectedBounds else { return }
        humanBounds = nil
        decision = .pending
        assert(bounds == detectedBounds)
    }

    public static let detectorVersion = "exact-hesitations/1:um,uh,erm,er"
    public static let configuredDetectorVersion = "configured-whole-words/2"

    public static func isHesitation(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        return ["um", "uh", "erm", "er"].contains(token)
    }

    public static func detections(in transcript: SpeakerTranscript, words: FillerWords = .defaults) -> [Self] {
        guard transcript.isValid, words.isValid else { return [] }
        return transcript.words.compactMap { word in
            guard words.contains(word.text), let bounds = FillerTimingBounds(word: word) else { return nil }
            return Self(origin: .detected, speaker: transcript.speaker, primary: transcript.primary,
                sourceRate: transcript.sourceRate, sourceIdentity: transcript.sourceIdentity,
                alignmentRevision: transcript.alignmentRevision, transcriptID: transcript.id, word: word,
                modelRecipe: transcript.model, analyzedRange: transcript.workingRange,
                detectorRecipe: configuredDetectorVersion, detectorWords: words,
                initialBounds: bounds, detectedBounds: bounds)
        }
    }

    /// Does not rebind by text or proximity when a transcript is replaced.
    public func matches(_ transcript: SpeakerTranscript) -> Bool {
        matchesOrigin(of: transcript) && word.map { captured in transcript.words.contains(captured) } != false
    }

    public func matchesOrigin(of transcript: SpeakerTranscript) -> Bool {
        transcriptID == transcript.id && speaker == transcript.speaker && primary == transcript.primary
            && sourceRate == transcript.sourceRate && sourceIdentity == transcript.sourceIdentity
            && alignmentRevision == transcript.alignmentRevision && modelRecipe == transcript.model
            && analyzedRange == transcript.workingRange
    }
}
