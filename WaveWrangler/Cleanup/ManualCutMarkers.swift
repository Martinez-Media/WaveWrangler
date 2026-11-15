import SwiftUI
import WWCore

struct ManualCutMarkers: View {
    @Bindable var model: EpisodeCleanupModel
    let selectContext: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let expandedID = model.expandedManualCut?.id
            let projection = model.cutTimeline
            ForEach(model.activeManualCuts) { cut in
                let time = projection.editedTime(forAlignedTime: cut.alignedStart)
                let x = (time - model.windowStart) / model.visibleDuration * geometry.size.width
                let select = {
                    selectContext()
                    model.selectManualCut(cut.id)
                }
                if expandedID == cut.id {
                    ManualCutInterval(model: model, cut: cut, size: geometry.size, select: select)
                } else if x >= 0, x <= geometry.size.width {
                    Rectangle().fill(.red).frame(width: 1.5, height: geometry.size.height)
                        .position(x: x, y: geometry.size.height / 2)
                        .allowsHitTesting(false)
                    ManualCutMarkerButton(model: model, cut: cut, time: time, select: select)
                        .position(x: min(max(12, x), max(12, geometry.size.width - 12)), y: 12)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct GlobalCutGuides: View {
    @Bindable var model: EpisodeCleanupModel

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for cut in model.activeManualCuts {
                    let start = model.cutTimeline.editedTime(forAlignedTime: cut.alignedStart)
                    let x = (start - model.windowStart) / model.visibleDuration * size.width
                    if model.expandedManualCut?.id == cut.id {
                        let end = model.cutTimeline.editedTime(forAlignedTime: cut.alignedEnd)
                        let right = (end - model.windowStart) / model.visibleDuration * size.width
                        let lower = max(0, x), upper = min(size.width, right)
                        if upper > lower {
                            context.fill(Path(CGRect(x: lower, y: 0, width: upper - lower, height: size.height)),
                                with: .color(.red.opacity(0.08)))
                        }
                    }
                    if x >= 0 && x <= geometry.size.width {
                        var seam = Path()
                        seam.move(to: CGPoint(x: x, y: 0))
                        seam.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(seam, with: .color(.red), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ManualCutMarkerButton: View {
    @Bindable var model: EpisodeCleanupModel
    let cut: ManualEpisodeCut
    let time: Double
    let select: () -> Void

    var body: some View {
        Button("Cross-track cut", systemImage: "scissors", action: select)
        .labelStyle(.iconOnly)
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(3)
        .background(.red, in: RoundedRectangle(cornerRadius: 3))
        .buttonStyle(.plain)
        .help("Select for inline cut tools. Show cut reveals the removed interval and its adjustable boundaries.")
        .accessibilityValue(
            String(
                format: "%.3f seconds removed at %.3f seconds",
                cut.alignedEnd - cut.alignedStart, time)
        )
        .accessibilityIdentifier("ww.timeline.cut.\(cut.id)")
        .contextMenu {
            Button("Zoom to cut", systemImage: "plus.magnifyingglass") {
                select()
                model.zoomToManualCut(cut.id)
            }
            Button("Show cut", systemImage: "eye") {
                select()
                model.showManualCut(cut.id, expanded: true)
            }
            Button("Hear removed audio", systemImage: "play.fill") {
                select()
                model.auditionManualCut(cut.id, mode: .removed)
            }
            Button("Hear edited join", systemImage: "play.rectangle") {
                select()
                model.auditionManualCut(cut.id, mode: .join)
            }
            Button("Restore interval markers", systemImage: "arrow.uturn.backward") {
                select()
                model.restoreManualCut(cut.id)
            }
            .disabled(!model.state.canEdit || model.isBusy || model.isRefreshing)
        }
    }

}

struct ManualCutToolbar: View {
    @Bindable var model: EpisodeCleanupModel
    let cut: ManualEpisodeCut

    private var expanded: Bool { model.expandedManualCut?.id == cut.id }

    var body: some View {
        HStack(spacing: 4) {
            Button("Zoom to cut", systemImage: "plus.magnifyingglass") {
                model.zoomToManualCut(cut.id)
            }
            .help("Center this cut with surrounding context. Preserve Show/Hide cut, playback time, and saved edits.")
            .accessibilityIdentifier("ww.timeline.cut.zoom")
            Button(expanded ? "Hide cut" : "Show cut", systemImage: expanded ? "eye.slash" : "eye") {
                model.showManualCut(cut.id, expanded: !expanded)
            }
            .help(
                expanded
                    ? "Collapse the removed interval back to its edited join. Saved cuts are unchanged."
                    : "Temporarily expand this cut to review removed audio and adjust its boundaries. Saved cuts are unchanged."
            )
            .accessibilityIdentifier("ww.timeline.cut.show")
            Button(expanded ? "Hear removed audio" : "Hear edited join", systemImage: "play.fill") {
                model.auditionManualCut(cut.id, mode: expanded ? .removed : .join)
            }
            .help(expanded
                ? "Play the audio removed by this cut using current Solo/Mute choices."
                : "Play the edited join with up to half a second on either side, using current Solo/Mute choices.")
            .accessibilityIdentifier("ww.timeline.cut.play")
            if expanded {
                Button("Hear cut with context", systemImage: "play.rectangle") {
                    model.auditionManualCut(cut.id, mode: .original)
                }
                .help("Play the removed audio with up to half a second before and after, using current Solo/Mute choices.")
                .accessibilityIdentifier("ww.timeline.cut.context")
            }
            if model.isPlaying || model.isPreparingPlayback {
                Button("Stop audition", systemImage: "stop.fill") { model.stopPlayback() }
                    .help("Stop the current cut audition.")
                    .accessibilityIdentifier("ww.timeline.cut.stop")
            }
            Button("Restore interval markers", systemImage: "arrow.uturn.backward") {
                model.restoreManualCut(cut.id)
            }
            .disabled(!model.state.canEdit || model.isBusy || model.isRefreshing)
            .help("Restore this cut's audio across all aligned tracks and select its interval. Other cuts remain applied.")
            .accessibilityIdentifier("ww.timeline.cut.restore")
            Button("Clear cut selection", systemImage: "xmark") { model.clearManualCutSelection() }
                .help("Deselect this cut and close its tools without restoring the removed audio.")
                .accessibilityIdentifier("ww.timeline.cut.clear")
        }
        .tint(.red)
        .labelStyle(.iconOnly)
    }
}

private struct ManualCutInterval: View {
    @Bindable var model: EpisodeCleanupModel
    let cut: ManualEpisodeCut
    let size: CGSize
    let select: () -> Void
    @State private var dragOrigin: ManualEpisodeCut?
    @State private var dragTime: Double?
    @State private var dragEdge: FillerTimingEdge?

    private var start: Double { dragEdge == .start ? dragTime ?? cut.alignedStart : cut.alignedStart }
    private var end: Double { dragEdge == .end ? dragTime ?? cut.alignedEnd : cut.alignedEnd }

    private func x(_ time: Double) -> Double {
        (model.cutTimeline.editedTime(forAlignedTime: time) - model.windowStart)
            / model.visibleDuration * size.width
    }

    var body: some View {
        let lo = max(0, x(start))
        let hi = min(size.width, x(end))
        ZStack(alignment: .topLeading) {
            if hi > lo {
                Rectangle().fill(.red.opacity(0.1))
                    .frame(width: hi - lo, height: size.height).offset(x: lo)
                    .onTapGesture(perform: select)
            }
            Canvas { context, _ in
                for time in [start, end] {
                    var rail = Path()
                    rail.move(to: CGPoint(x: x(time), y: 0))
                    rail.addLine(to: CGPoint(x: x(time), y: size.height))
                    context.stroke(rail, with: .color(.red), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                }
            }.allowsHitTesting(false)
            handle(.start, time: start)
            handle(.end, time: end)
        }
        .coordinateSpace(name: cut.id)
        .allowsHitTesting(model.listening.effectiveTool != .move && model.listening.effectiveTool != .automation)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.timeline.cut.expanded.\(cut.id)")
    }

    @ViewBuilder
    private func handle(_ edge: FillerTimingEdge, time: Double) -> some View {
        if dragEdge == edge || (x(time) >= 0 && x(time) <= size.width) {
            AudioTimelineBoundaryControl(
                edge: edge, color: .red, title: "Cut \(edge == .start ? "start" : "end") handle",
                time: time, identifier: "ww.timeline.cut.\(cut.id).\(edge == .start ? "start" : "end")",
                enabled: model.canEditManualCuts,
                select: select,
                nudge: { seconds in commit(edge, time: time + seconds, original: cut) }
            )
            .offset(
                x: min(max(0, x(time) - 9), max(0, size.width - 18)),
                y: edge == .start ? 0 : max(0, size.height - 18)
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(cut.id))
                    .onChanged { value in
                        guard model.canEditManualCuts, model.listening.effectiveTool == .select else { return }
                        if dragOrigin == nil {
                            dragOrigin = cut
                            dragEdge = edge
                            select()
                        }
                        if let origin = dragOrigin {
                            dragTime = movedTime(edge, original: origin, translation: value.translation.width)
                        }
                    }
                    .onEnded { value in
                        if model.listening.effectiveTool == .select, let origin = dragOrigin {
                            commit(
                                edge, time: movedTime(edge, original: origin, translation: value.translation.width),
                                original: origin)
                        }
                        dragOrigin = nil
                        dragTime = nil
                        dragEdge = nil
                    })
        }
    }

    private func movedTime(_ edge: FillerTimingEdge, original: ManualEpisodeCut, translation: Double) -> Double {
        let origin = edge == .start ? original.alignedStart : original.alignedEnd
        let proposed = model.cutTimeline.alignedTime(
            forEditedTime:
                model.cutTimeline.editedTime(forAlignedTime: origin)
                + translation / max(1, size.width) * model.visibleDuration)
        let bounds = model.originalCutBounds ?? original.alignedStart...original.alignedEnd
        return edge == .start
            ? max(bounds.lowerBound, min(proposed, original.alignedEnd - 1 / 48_000))
            : min(bounds.upperBound, max(proposed, original.alignedStart + 1 / 48_000))
    }

    private func commit(_ edge: FillerTimingEdge, time: Double, original: ManualEpisodeCut) {
        select()
        _ = model.adjustManualCut(
            original,
            start: edge == .start ? time : original.alignedStart,
            end: edge == .end ? time : original.alignedEnd)
    }
}
