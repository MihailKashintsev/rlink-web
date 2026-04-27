import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + Lock Screen Live Activity for Rlink BLE messenger
@available(iOS 16.2, *)
struct RlinkLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RlinkActivityAttributes.self) { context in
            // Lock Screen / banner presentation
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.18))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.connectedPeers)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("server users online")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.state.connectedPeers) users")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }
            } compactLeading: {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.connectedPeers)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            } minimal: {
                Text("\(context.state.connectedPeers)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }

    // MARK: - Signal Bars (expanded)
    @ViewBuilder
    private func signalBars(level: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? signalColor(level) : Color.white.opacity(0.2))
                    .frame(width: 4, height: CGFloat(6 + i * 4))
            }
        }
        .frame(height: 14, alignment: .bottom)
    }

    // MARK: - Signal Bars (compact)
    @ViewBuilder
    private func signalBarsCompact(level: Int) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? signalColor(level) : Color.white.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
        .frame(height: 10, alignment: .bottom)
    }

    // MARK: - Signal Label
    @ViewBuilder
    private func signalLabel(level: Int) -> some View {
        Text(signalText(level))
            .font(.caption2)
            .foregroundStyle(signalColor(level))
    }

    private func signalText(_ level: Int) -> String {
        switch level {
        case 0: return "Нет сигнала"
        case 1: return "Слабый"
        case 2: return "Средний"
        default: return "Сильный"
        }
    }

    private func signalColor(_ level: Int) -> Color {
        switch level {
        case 0: return .gray
        case 1: return .red
        case 2: return .yellow
        default: return .green
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RlinkActivityAttributes>) -> some View {
        Group {
            if context.state.uiMode == 1 {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(.cyan.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.mediaLabel.isEmpty ? "Отправка" : context.state.mediaLabel)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        ProgressView(value: min(1, max(0, context.state.mediaProgress)))
                            .tint(.cyan)
                        Text("\(Int((context.state.mediaProgress * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(.green.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.green)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Rlink")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(context.state.connectedPeers) server online")
                                .font(.caption)
                                .foregroundStyle(.green.opacity(0.9))
                        }

                        Text(context.state.connectedPeers > 0 ? "Internet mode" : "Internet mode · no users")
                            .font(.system(size: 13))
                            .foregroundStyle(.green.opacity(0.9))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
}
