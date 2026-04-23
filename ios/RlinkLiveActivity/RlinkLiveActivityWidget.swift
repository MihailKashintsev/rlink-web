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
        } dynamicIsland: { context in
            DynamicIsland {
                if context.state.uiMode == 1 {
                    DynamicIslandExpandedRegion(.leading) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        Text("\(Int((context.state.mediaProgress * 100).rounded()))%")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    DynamicIslandExpandedRegion(.center) {
                        VStack(spacing: 4) {
                            Text(context.state.mediaLabel.isEmpty ? "Отправка" : context.state.mediaLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            ProgressView(value: min(1, max(0, context.state.mediaProgress)))
                                .tint(.cyan)
                        }
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        Text("Крупный файл — Rlink")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    DynamicIslandExpandedRegion(.leading) {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.green)
                            Text("\(context.state.connectedPeers)")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        signalBars(level: context.state.signalLevel)
                    }
                    DynamicIslandExpandedRegion(.center) {
                        VStack(spacing: 2) {
                            if context.state.connectedPeers > 0 {
                                Text(context.state.connectedPeers == 1
                                     ? "1 устройство рядом"
                                     : "\(context.state.connectedPeers) устройств рядом")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("Поиск устройств…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        HStack {
                            Image(systemName: "bluetooth")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            Text("Rlink Mesh")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            signalLabel(level: context.state.signalLevel)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                if context.state.uiMode == 1 {
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.cyan)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("\(context.state.connectedPeers)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            } compactTrailing: {
                if context.state.uiMode == 1 {
                    Text("\(Int((context.state.mediaProgress * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                } else {
                    signalBarsCompact(level: context.state.signalLevel)
                }
            } minimal: {
                if context.state.uiMode == 1 {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.cyan)
                } else {
                    Text("\(context.state.connectedPeers)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }
            }
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
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.green)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Rlink")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            signalBars(level: context.state.signalLevel)
                            Text("\(context.state.connectedPeers) рядом")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(context.state.connectedPeers > 0 ? "Mesh активна" : "Поиск устройств...")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }
}
