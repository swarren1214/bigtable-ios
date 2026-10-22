import SwiftUI

/// The running cooking timer: a ring counting down, +1 min and Pause.
struct TimerView: View {
    @Environment(CookTimer.self) private var timer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let remaining = timer.remaining(at: context.date)
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: timer.progress(at: context.date))
                        .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(Duration.seconds(remaining.rounded(.up)).formatted(.time(pattern: remaining >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                            .minimumScaleFactor(0.6)
                        Text(timer.isActive ? (timer.isPaused ? "Paused" : "of \(Int(timer.duration / 60)) min") : "Done")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle(timer.label.isEmpty ? "Timer" : timer.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("+1 min") { timer.addMinute() }
                    .disabled(!timer.isActive)
                Spacer()
                Button {
                    timer.togglePause()
                } label: {
                    Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                }
                .accessibilityLabel(timer.isPaused ? "Resume" : "Pause")
                .disabled(!timer.isActive)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    timer.stop()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Stop timer")
                .disabled(!timer.isActive)
            }
        }
        // Taps the wrist at zero while the timer's on screen (a notification does otherwise).
        .task(id: timer.endsAt) {
            guard let end = timer.endsAt else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            timer.finished()
        }
    }
}
