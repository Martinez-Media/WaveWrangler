import AppKit
import SwiftUI
import WWOrganizer

struct WorkspaceBottomPaneToggles: View {
    @Bindable var state: ShowWindowState

    var body: some View {
        WorkspaceToolbarSegments(items: EpisodeBottomPaneContent.allCases.map { content in
            let detached = state.workspaceIsDetached(content)
            let shown = state.bottomPanePresented && state.bottomPaneContent == content
            return .init(
                id: content == .recordings ? "ww.show.recordings" : "ww.\(content.rawValue.lowercased()).toggle",
                title: content.rawValue, symbol: content.symbol, selected: detached || shown,
                value: detached ? "In separate window" : shown ? "Shown" : "Hidden",
                help: "Show or focus \(content.rawValue). Option-click to "
                    + (AppSettings.shared.workspacesInSeparateWindows ? "open in the bottom panel." : "open a separate window."))
        }) { index in
            state.toggleWorkspace(EpisodeBottomPaneContent.allCases[index],
                                  alternatePlacement: NSEvent.modifierFlags.contains(.option))
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bottom panes")
    }
}

struct WorkspaceInspectorToggles: View {
    @Bindable var state: ShowWindowState
    private let activities: [ShowWindowState.WorkspaceInspector] = [.recording, .episode]

    var body: some View {
        WorkspaceToolbarSegments(items: activities.map { activity in
            let active = state.inspectorPresented && state.workspaceInspector == activity
            return .init(id: "ww.sidebar.\(activity.identifier)", title: "\(activity.title) inspector",
                         symbol: activity.symbol, selected: active, value: active ? "Shown" : "Hidden",
                         help: "\(active ? "Hide" : "Show") \(activity.title) inspector")
        }) { index in
            state.toggleWorkspaceInspector(activities[index])
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar activities")
    }
}

private struct WorkspaceToolbarSegments: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let selected: Bool
        let value: String
        let help: String
    }

    let items: [Item]
    let activate: (Int) -> Void

    var body: some View {
        NativeControl(owner: self)
            .fixedSize()
            // Preserve explicit action names and detached-window values for each native segment.
            .accessibilityRepresentation {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button(item.title) { activate(index) }
                            .frame(width: 32, height: 32)
                            .accessibilityValue(item.value)
                            .accessibilityAddTraits(item.selected ? [.isSelected] : [])
                            .accessibilityIdentifier(item.id)
                            .help(item.help)
                    }
                }
            }
    }

    private struct NativeControl: NSViewRepresentable {
        let owner: WorkspaceToolbarSegments

        func makeCoordinator() -> Coordinator { Coordinator(owner) }

        func makeNSView(context: Context) -> NSSegmentedControl {
            let control = NSSegmentedControl()
            control.trackingMode = .selectAny
            control.segmentStyle = .automatic
            control.controlSize = .large
            control.target = context.coordinator
            control.action = #selector(Coordinator.segmentChanged(_:))
            return control
        }

        func updateNSView(_ control: NSSegmentedControl, context: Context) {
            context.coordinator.owner = owner
            control.target = context.coordinator
            control.action = #selector(Coordinator.segmentChanged(_:))
            if control.segmentCount != owner.items.count { control.segmentCount = owner.items.count }
            for (index, item) in owner.items.enumerated() {
                let image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)?
                    .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
                control.setImage(image, forSegment: index)
                control.setWidth(32, forSegment: index)
                control.setSelected(item.selected, forSegment: index)
                control.setToolTip(item.help, forSegment: index)
            }
        }
    }

    final class Coordinator: NSObject {
        var owner: WorkspaceToolbarSegments
        init(_ owner: WorkspaceToolbarSegments) { self.owner = owner }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard owner.items.indices.contains(index) else { return }
            owner.activate(index)
            for (index, item) in owner.items.enumerated() {
                sender.setSelected(item.selected, forSegment: index)
            }
        }
    }
}

/// Toolbar save-status item (states §2): symbol + short text; opens a popover with details and actions.
/// Never says "Saved" unless the status model reports coherent publication (D1).
struct SaveStatusItem: View {
    @Bindable var state: ShowWindowState
    @FocusState private var focused: Bool

    var body: some View {
        let presentation = state.presentation
        Button {
            state.saveStatusPopoverShown.toggle()
        } label: {
            HStack(spacing: 4) {
                if let symbol = presentation.symbolName {
                    Image(systemName: symbol)
                        .foregroundStyle(tint(presentation.tint))
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text(presentation.itemText)
                    .lineLimit(1)
            }
        }
        .help(presentation.popoverText)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
        .accessibilityIdentifier("ww.show.saveStatus")
        .focused($focused)
        .onChange(of: state.saveStatusFocusRequest) { _, _ in focused = true }
        .popover(isPresented: $state.saveStatusPopoverShown, arrowEdge: .bottom) {
            SaveStatusPopover(state: state, presentation: presentation)
                .wwAppEnvironment()
        }
    }

    private func tint(_ tint: StatusTint) -> Color {
        switch tint {
        case .none: .secondary
        case .attention: .orange
        case .failed: .red
        }
    }
}

private struct SaveStatusPopover: View {
    let state: ShowWindowState
    let presentation: SaveStatusPresentation
    @FocusState private var focusedAction: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.itemText)
                .wwFont(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(presentation.popoverText)
                .wwFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
            if !presentation.actions.isEmpty {
                HStack {
                    ForEach(Array(presentation.actions.enumerated()), id: \.element) { index, action in
                        Button(action.rawValue) {
                            state.saveStatusPopoverShown = false
                            state.perform(action)
                        }
                        .focused($focusedAction, equals: index)
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 400)
        .accessibilityIdentifier("ww.show.saveStatus.popover")
        // The popover itself (AppKit's frame around this content) needs a description too (A11Y audit, #157).
        .background(PopoverAccessibilityLabel(label: "Save status details"))
        .onAppear { focusedAction = presentation.actions.isEmpty ? nil : 0 }
    }
}

/// Gives the AppKit popover hosting this SwiftUI content an accessibility description: SwiftUI's `.popover` has no
/// API for it, and VoiceOver and the accessibility audit otherwise see an undescribed popover.
private struct PopoverAccessibilityLabel: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> NSView { LabelView(label: label) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class LabelView: NSView {
        let label: String

        init(label: String) {
            self.label = label
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.setAccessibilityLabel(label)
            // The popover element VoiceOver reports is the window's frame view.
            window.contentView?.superview?.setAccessibilityLabel(label)
        }
    }
}
