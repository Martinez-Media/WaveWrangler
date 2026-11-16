import SwiftUI
import WWCore

struct ReviewFillerWordsSettings: View {
    @Bindable var store: ShowDocumentStore
    let episodeID: EpisodeID
    @State private var speakerID: SpeakerID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filler Words").wwFont(.headline)
                Picker("Scope", selection: $speakerID) {
                    Text("This show").tag(SpeakerID?.none)
                    ForEach(store.residentModel.speakers.filter {
                        store.residentModel.episode(episodeID)?.assignment(for: $0.id) != nil
                    }) { speaker in
                        Text(speaker.name).tag(Optional(speaker.id))
                    }
                }
                .accessibilityIdentifier("ww.review.fillerWords.scope")
                .accessibilityLabel("Filler-word scope")
                DocumentFillerWordsEditor(store: store, speakerID: speakerID, expanded: true)
                    .id(speakerID)
                Button("App Filler-Word Defaults…") { SettingsWindowController.show(pane: .transcription) }
            }
            .padding(16)
        }
        .frame(width: 420, height: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filler Words")
    }
}

struct FillerWordsInput: View {
    let value: FillerWords?
    let identifier: String
    let apply: (FillerWords) -> Void
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var wordsFocused: Bool

    private let guidance = "Whole words only, separated by commas or new lines. Matching ignores case and surrounding punctuation. An empty list turns off suggestions."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Words separated by commas", text: $draft, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .focused($wordsFocused)
                .accessibilityLabel(error == nil ? "Filler words" : "Filler words, invalid entry")
                .accessibilityHint(error ?? guidance)
                .accessibilityIdentifier("\(identifier).words")
                .onSubmit(save)
            Text(guidance)
                .wwFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Apply Words", action: save)
                .disabled(draft == value?.words.joined(separator: ", "))
                .accessibilityIdentifier("\(identifier).apply")
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).error")
            }
        }
        .onChange(of: value, initial: true) { _, value in
            draft = value?.words.joined(separator: ", ") ?? ""
            error = nil
        }
        .onChange(of: draft) { _, _ in error = nil }
    }

    private func save() {
        do {
            let words = try FillerWords(text: draft)
            apply(words)
            error = nil
        } catch {
            let message = "Enter up to 128 single words (letters only, at most 64 UTF-8 bytes each). Phrases are not supported."
            if self.error != message { AccessibilityNotification.Announcement(message).post() }
            self.error = message
            wordsFocused = true
        }
    }
}

struct AppFillerWordsEditor: View {
    @Bindable var settings: AppSettings = .shared

    var body: some View {
        FillerWordsInput(value: settings.fillerWords, identifier: "ww.settings.fillers") {
            settings.setFillerWords($0)
        }
        if let error = settings.fillerWordsError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
        Button("Restore Default Words") { settings.setFillerWords(.defaults) }
            .accessibilityIdentifier("ww.settings.fillers.restore")
        Text("Defaults: er, erm, uh, um. Shows and speakers can override this list. The next transcription or explicit Find Filler Candidates scan uses these words. Judgments and cuts are never changed by word settings or scans.")
            .wwFont(.caption)
    }
}

struct DocumentFillerWordsEditor: View {
    @Bindable var store: ShowDocumentStore
    var speakerID: SpeakerID?
    @State var expanded = false
    @Bindable private var settings: AppSettings = .shared

    private var override: FillerWords? {
        if let speakerID { return store.residentModel.speaker(speakerID)?.fillerWords }
        return store.residentModel.show.fillerWords
    }

    private var inherited: FillerWords? {
        if speakerID != nil { return store.residentModel.show.fillerWords ?? settings.fillerWords }
        return settings.fillerWords
    }

    private var identifier: String { speakerID == nil ? "ww.show.fillers" : "ww.speaker.fillers" }

    var body: some View {
        DisclosureGroup("Filler words", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(speakerID.map { "Speaker: \(store.residentModel.speaker($0)?.name ?? "Removed speaker") · applies throughout this show" }
                    ?? "Show: \(store.residentModel.show.title)")
                    .wwFont(.callout)
                if let override {
                    FillerWordsInput(value: override, identifier: identifier) { save($0) }
                    Button(speakerID == nil ? "Use App Defaults" : "Use Show Defaults") { save(nil) }
                        .accessibilityIdentifier("\(identifier).inherit")
                } else {
                    Text(speakerID != nil && store.residentModel.show.fillerWords != nil
                        ? "Using show words" : "Using app defaults")
                    if let inherited {
                        Text(inherited.words.isEmpty ? "No automatic filler suggestions" : inherited.words.joined(separator: ", "))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Customize Words") { save(inherited) }
                            .accessibilityIdentifier("\(identifier).customize")
                    } else if let error = settings.fillerWordsError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Text("Changing words does not edit transcripts or cuts. Find Filler Candidates refreshes pending suggestions; reviewed, rejected, adjusted, manual and cut-linked intervals are retained.")
                    .wwFont(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .disabled(!store.canEdit || (speakerID.map { store.residentModel.speaker($0) == nil } ?? false))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func save(_ words: FillerWords?) {
        let expected = override
        store.apply(speakerID == nil ? "Change Show Filler Words" : "Change Speaker Filler Words") { model throws(DomainError) in
            let live = speakerID.flatMap { model.speaker($0)?.fillerWords } ?? (speakerID == nil ? model.show.fillerWords : nil)
            guard live == expected else { throw .invalidFillerWords }
            return try model.settingFillerWords(words, for: speakerID)
        }
    }
}
