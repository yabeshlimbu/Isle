import AppKit
import SwiftUI

// MARK: - Circles beside the notch

/// A row of activity circles. Tapping one opens what it belongs to.
struct ActivityCircles: View {
    let kinds: [ActivityKind]
    let diameter: CGFloat
    let features: Features
    let open: (ActivityKind) -> Void

    var body: some View {
        HStack(spacing: IslandMetrics.circleGap) {
            ForEach(kinds, id: \.self) { kind in
                Button { open(kind) } label: {
                    circle(kind)
                        .frame(width: diameter, height: diameter)
                        .background(Circle().fill(Color.black))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private func circle(_ kind: ActivityKind) -> some View {
        switch kind {
        case .keepAwake: KeepAwakeCircle()
        case .meeting: MeetingCircle(activities: features.activities)
        case .timer: TimerCircle(timer: features.timer)
        case .download: DownloadCircle(downloads: features.downloads)
        }
    }
}

/// Progress ring around a circle's content.
struct Ring: View {
    let fraction: Double
    let color: Color
    var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
            if spinning {
                TimelineView(.animation) { context in
                    let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
                    Circle().trim(from: 0, to: 0.25)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(angle))
                }
            } else {
                Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .padding(2)
    }
}

private struct KeepAwakeCircle: View {
    var body: some View {
        Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.yellow)
            .help("Keep awake is on · click to turn off")
    }
}

private struct MeetingCircle: View {
    @ObservedObject var activities: ActivityCenter

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let event = activities.meeting {
                let left = event.start.timeIntervalSince(context.date)
                ZStack {
                    Ring(fraction: max(left, 0) / ActivityCenter.meetingLead, color: Color(nsColor: event.color))
                    Text(left > 0 ? "\(Int((left / 60).rounded(.up)))m" : "now")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                }
                .help(left > 0 ? "\(event.title) starts in \(Int((left / 60).rounded(.up))) min" : "\(event.title) has started")
            }
        }
    }
}

private struct TimerCircle: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let left = timer.remaining(at: context.date)
            ZStack {
                Ring(fraction: timer.fractionLeft(at: context.date), color: timer.isRunning ? .green : .orange)
                Text(TimerModel.short(left))
                    .font(.system(size: 8.5, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(timer.isRunning ? Color.white : Color.orange)
            }
            .help(timer.isRunning ? "Timer · \(TimerModel.format(left)) left" : "Timer paused")
        }
    }
}

private struct DownloadCircle: View {
    @ObservedObject var downloads: DownloadMonitor

    var body: some View {
        ZStack {
            Ring(fraction: downloads.fraction ?? 0, color: downloads.justFinished ? .green : .blue,
                 spinning: downloads.fraction == nil)
            if downloads.justFinished {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
            } else if let f = downloads.fraction {
                Text("\(Int((f * 100).rounded(.down)))")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
            } else {
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
            }
        }
        .help(downloads.justFinished ? "Downloaded \(downloads.name)" : "Downloading \(downloads.name)")
    }
}

// MARK: - Notification banner

struct BannerView: View {
    let banner: Banner

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let id = banner.appBundleID {
                    AppIcon(bundleID: id)
                } else {
                    Image(systemName: banner.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15)))
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !banner.body.isEmpty {
                    Text(banner.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("now")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Timer tab

struct TimerPanel: View {
    @ObservedObject var timer: TimerModel
    private let presets: [Int] = [1, 3, 5, 10, 15, 25, 30, 60]

    var body: some View {
        if timer.isActive {
            HStack(spacing: 24) {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    ZStack {
                        Ring(fraction: timer.fractionLeft(at: context.date), color: timer.isRunning ? .green : .orange)
                            .frame(width: 76, height: 76)
                        Text(TimerModel.format(timer.remaining(at: context.date)))
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if timer.isRunning {
                            PillButton(title: "Pause", symbol: "pause.fill") { timer.pause() }
                        } else {
                            PillButton(title: "Resume", symbol: "play.fill") { timer.resume() }
                        }
                        PillButton(title: "Cancel", symbol: "xmark") { timer.cancel() }
                    }
                    HStack(spacing: 8) {
                        PillButton(title: "+1 min") { timer.add(60) }
                        PillButton(title: "+5 min") { timer.add(300) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Text("Start a timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4), spacing: 8) {
                    ForEach(presets, id: \.self) { m in
                        Button { timer.start(TimeInterval(m * 60)) } label: {
                            Text(m == 60 ? "1 hr" : "\(m) min")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 64, height: 26)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
