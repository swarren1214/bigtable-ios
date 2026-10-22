import SwiftUI
import UIKit

/// Cook Mode: one step at a time, big, with that step's ingredients, its timer and big Back
/// and Next buttons. iPhone Duo's signature pose: set down partly folded (Laptop), the step
/// reads on the upright half and the controls sit on the half lying flat (`HearthFoldOverlay`).
/// Flat, the controls float at the bottom of the step. The step and the timer live in
/// `CookSession`, so closing or folding the phone, or the Across the Kitchen board, never
/// loses them. The screen stays awake while it shows.
///
/// Presented full screen from Start Cooking; the recipe page also shows it in place when the
/// phone is set down in Laptop (`CookModeContent`).
struct CookModeView: View {
    @State private var cook = CookSession.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CookModeContent()
                .navigationTitle(cook.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCancelButton("Close") { dismiss() }
                    }
                }
        }
        // Done Cooking on the last step closes it.
        .onChange(of: cook.isCooking) { _, cooking in
            if !cooking { dismiss() }
        }
    }
}

/// Cook Mode's page, without a navigation bar of its own: the step above, the controls below
/// (or on the flat half in Laptop), and the toolbar button for the Across the Kitchen board.
struct CookModeContent: View {
    /// Off when the host presents the board itself (the recipe page in Laptop, so the board
    /// stays up when the pose changes and this view goes away).
    var presentsBoard = true

    @State private var cook = CookSession.shared
    @Environment(\.accent) private var accent

    var body: some View {
        HearthFoldOverlay {
            controls
        } content: {
            stepPage
        }
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Tent: the outer display, standing by the stove. The system can't tell
                // Tent from Closed, so the board opens from here.
                HearthGlanceBoardButton(title: "Across the Kitchen", systemImage: "timer") {
                    cook.showsBoard = true
                }
                // Not a confirm button: the text color, not the app's (AGENT.md).
                .tint(.primary)
            }
        }
        .fullScreenCover(isPresented: boardBinding) {
            CookGlanceBoard()
                .environment(\.accent, accent)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // The board lets the screen sleep when it closes; Cook Mode is still up.
        .onChange(of: cook.showsBoard) { _, shows in
            if !shows { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }

    /// The board's presentation, when this view presents it.
    private var boardBinding: Binding<Bool> {
        Binding(
            get: { presentsBoard && cook.showsBoard },
            set: { cook.showsBoard = $0 }
        )
    }

    // MARK: The step (above the fold)

    private var stepPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if cook.steps.isEmpty {
                    Text("This recipe has no steps yet.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Step \(cook.stepIndex + 1) of \(cook.steps.count)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Text(cook.currentStep)
                        .font(.title.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .id(cook.stepIndex)
                        .transition(.opacity)
                    if let next = cook.nextStep {
                        Text("Next: \(next)")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: BigTableScreen<EmptyView>.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth, value: cook.stepIndex)
        }
    }

    // MARK: The controls (the flat half)

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepIngredients
            timerRow
            HStack(spacing: 12) {
                Button {
                    withAnimation(.snappy) { cook.back() }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(.primary)
                .disabled(cook.isFirstStep)

                if cook.isLastStep {
                    Button {
                        cook.finish()
                    } label: {
                        Label("Done Cooking", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        withAnimation(.snappy) { cook.next() }
                    } label: {
                        Label("Next Step", systemImage: "chevron.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    // Voice Control: "Next step" with floury hands.
                    .accessibilityInputLabels([Text("Next Step"), Text("Next")])
                }
            }
        }
        .padding(16)
        .frame(maxWidth: BigTableScreen<EmptyView>.readableWidth)
        .glassEffect(in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    /// The ingredients this step names, with the amounts chosen on the recipe page.
    @ViewBuilder
    private var stepIngredients: some View {
        let items = cook.currentStepIngredients
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("For this step")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(items) { ingredient in
                        let parts = cook.amountParts(ingredient)
                        Text([parts.quantity, parts.name].filter { !$0.isEmpty }.joined(separator: " "))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
            }
        }
    }

    /// The running timer (pause, a minute more, stop), or the step's own timer to start.
    @ViewBuilder
    private var timerRow: some View {
        if cook.hasTimer {
            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = cook.remaining(at: context.date)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(left > 0 ? CookSession.clock(left) : "Done")
                            .font(.title.bold().monospacedDigit())
                            .foregroundStyle(accent)
                        Text(cook.isTimerPaused ? "\(cook.timerLabel), paused" : cook.timerLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                Group {
                    Button {
                        cook.toggleTimerPause()
                    } label: {
                        Label(cook.isTimerPaused ? "Resume Timer" : "Pause Timer", systemImage: cook.isTimerPaused ? "play.fill" : "pause.fill")
                    }
                    Button {
                        cook.addMinute()
                    } label: {
                        Label("Add a Minute", systemImage: "goforward.60")
                    }
                    Button {
                        cook.stopTimer()
                    } label: {
                        Label("Stop Timer", systemImage: "stop.fill")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(.primary)
            }
        } else if let seconds = cook.currentStepSeconds {
            Button {
                cook.startStepTimer()
            } label: {
                Label("Start \(CookSession.shortDuration(seconds)) Timer", systemImage: "timer")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(.primary)
        }
    }
}

/// Across the Kitchen (Tent): the outer display standing by the stove, the timer readable from
/// across the room with the step underneath. The same step as Cook Mode: advancing here
/// advances there. Its rail holds Pause, Next and Back.
struct CookGlanceBoard: View {
    @State private var cook = CookSession.shared
    @Environment(\.accent) private var accent

    var body: some View {
        HearthGlanceBoard(cook.title, color: accent) {
            VStack(spacing: 20) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if cook.hasTimer {
                        let left = cook.remaining(at: context.date)
                        HearthGlanceFigure(
                            value: left > 0 ? CookSession.clock(left) : "Done",
                            label: cook.isTimerPaused ? "\(cook.timerLabel), paused" : cook.timerLabel
                        )
                    } else {
                        HearthGlanceFigure(value: "Step \(cook.stepIndex + 1)", label: "of \(cook.steps.count)")
                    }
                }
                Text(cook.currentStep)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                if let next = cook.nextStep {
                    Text("Next: \(next)")
                        .font(.title3)
                        .opacity(0.85)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
            .animation(.smooth, value: cook.stepIndex)
        } actions: {
            ToolbarItemGroup(placement: .primaryAction) {
                if cook.hasTimer {
                    Button {
                        cook.toggleTimerPause()
                    } label: {
                        Label(cook.isTimerPaused ? "Resume Timer" : "Pause Timer", systemImage: cook.isTimerPaused ? "play.fill" : "pause.fill")
                    }
                } else if cook.currentStepSeconds != nil {
                    Button {
                        cook.startStepTimer()
                    } label: {
                        Label("Start Timer", systemImage: "timer")
                    }
                }
                Button {
                    cook.next()
                } label: {
                    Label("Next Step", systemImage: "chevron.right")
                }
                .disabled(cook.isLastStep)
                // Voice Control: "Next step" from across the kitchen.
                .accessibilityInputLabels([Text("Next Step"), Text("Next")])
                Button {
                    cook.back()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(cook.isFirstStep)
            }
        }
        // White on the app's color, like the board's text.
        .tint(.white)
    }
}
