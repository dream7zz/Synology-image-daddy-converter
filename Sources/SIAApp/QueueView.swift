import SwiftUI
import SIACore

extension Job: Identifiable {}

/// Dedicated queue window: overall progress plus a per-task row with separate
/// download / convert / upload bars.
struct QueueView: View {
    @ObservedObject var state: AppState
    @StateObject private var ui = QueueUI()

    var body: some View {
        // Compute once per update; filtering 167k rows per subview was the lag.
        let page = state.queuePage(filter: ui.filter, limit: ui.limit)
        return VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            chipRow(page.total)
            Divider().overlay(Theme.stroke)
            list(page.rows, total: page.total)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    // MARK: header

    private var header: some View {
        let p = state.overallProgress
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("任务队列").font(Theme.title(15))
                Text(state.phaseText)
                    .font(Theme.mono(9))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.panelRaised)
                    .clipShape(Capsule())
                    .foregroundStyle(state.isBusy ? Theme.accent : Theme.textFaint)
                Spacer()
                IconButton(systemImage: "pause.fill", help: "暂停") { state.pause() }
                    .disabled(state.phase != .running)
                IconButton(systemImage: "playpause.fill", help: "继续") { state.resume() }
                    .disabled(state.phase != .paused)
                IconButton(systemImage: "stop.fill", help: "停止") { state.stop() }
                    .disabled(!state.isBusy)
            }

            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.panelRaised)
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.accent.opacity(0.8), Theme.accent],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, geo.size.width * p.fraction))
                            .animation(.easeOut(duration: 0.3), value: p.fraction)
                    }
                }
                .frame(height: 8)

                Text(p.fraction >= 0.1
                     ? "\(Int(p.fraction * 100))%"
                     : String(format: "%.1f%%", p.fraction * 100))
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 46, alignment: .trailing)
            }

            HStack(spacing: 14) {
                let t = state.queueTally
                stat("本次完成", "\(t.done)/\(t.total)", Theme.success)
                stat("进行中", "\(t.active)", Theme.accent)
                stat("排队", "\(t.pending)", Theme.textDim)
                stat("失败", "\(t.failed)", Theme.danger)
                stat("跳过", "\(t.skipped)", Theme.textFaint)
                Spacer()
                Text("库内：" + scopeSummary)
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                if let eta = state.etaText {
                    Text("剩余 \(eta)").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
            }

            if let job = state.activeJob {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text(job.filename).font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(16)
        .background(Theme.panel)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.body(10)).foregroundStyle(Theme.textFaint)
            Text(value).font(Theme.mono(11, weight: .medium)).foregroundStyle(color)
        }
    }

    // MARK: filters

    private func chipRow(_ total: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(AppState.JobFilter.allCases, id: \.self) { f in
                Button { ui.filter = f; ui.limit = 100 } label: {
                    Text(f.label)
                        .font(Theme.body(10))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(ui.filter == f ? Theme.accent.opacity(0.18) : Theme.panelRaised)
                        .foregroundStyle(ui.filter == f ? Theme.accent : Theme.textDim)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(total) 项")
                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: list

    private func list(_ rows: [Job], total: Int) -> some View {
        let shown = rows
        if shown.isEmpty {
            return AnyView(
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.textFaint)
                    Text(state.phase == .running || state.phase == .paused
                         ? "当前筛选下没有任务"
                         : "点「开始」后这里会显示每个文件的进度")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        return AnyView(ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(shown) { job in
                    QueueRow(job: job, state: state)
                    Divider().overlay(Theme.stroke.opacity(0.6))
                }
                if total > shown.count {
                    Button {
                        ui.limit += 200
                    } label: {
                        Text("显示更多（还有 \(total - shown.count)）")
                            .font(Theme.body(11))
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
        })
    }
}

extension AppState.JobFilter {
    var label: String {
        switch self {
        case .active: return "进行中"
        case .pending: return "排队"
        case .failed: return "失败"
        case .skipped: return "跳过"
        case .done: return "已完成"
        case .all: return "全部"
        }
    }
}

final class QueueUI: ObservableObject {
    @Published var filter: AppState.JobFilter = .all
    @Published var limit: Int = 100
}

extension QueueView {
    /// Same numbers as the sidebar: 缺失 · 就绪 · 总数.
    var scopeSummary: String {
        // Partial numbers during a scan would look like a bug; say what's up.
        if state.phase == .scanning { return "扫描中，完成后显示统计" }
        let c = state.libraryCounts
        return "缺失 \(c.missing) · 就绪 \(c.ready) · 总 \(c.total)"
    }
}

struct QueueRow: View {
    let job: Job
    @ObservedObject var state: AppState

    var body: some View {
        let f = state.stageFractions(for: job.id)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.filename)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(job.bytes), countStyle: .file))
                    Text(state.stageLabel(job))
                        .foregroundStyle(colour(job.stage))
                }
                .font(Theme.mono(9))
                .foregroundStyle(Theme.textFaint)
            }
            .frame(width: 240, alignment: .leading)

            if job.stage == .fetching {
                StageBar(title: "下载", fraction: f.down, active: true)
            } else if [.failed, .blocked, .cancelled].contains(job.stage) {
                // Show why it failed instead of a bare "失败".
                Text(state.failureText(job))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(job.message)
            } else {
                Text("—")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // 转换 and 回传 have no measurable granularity; showing a bar that
            // jumps 0 → 100 reads as broken, so they are text-only states.
            Text(state.stageLabel(job))
                .font(Theme.mono(10))
                .foregroundStyle(colour(job.stage))
                .frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func colour(_ s: JobStage) -> Color {
        switch s {
        case .done: return Theme.success
        case .failed, .blocked, .cancelled: return Theme.danger
        case .fetching, .converting, .uploading: return Theme.accent
        case .readyToUpload: return Theme.warning
        default: return Theme.textFaint
        }
    }
}

struct StageBar: View {
    let title: String
    let fraction: Double
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(Theme.mono(8)).foregroundStyle(Theme.textFaint)
                if fraction >= 1 {
                    Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.success)
                }
            }
            Group {
                if active && fraction <= 0.001 {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(Theme.accent)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.panelRaised)
                            Capsule()
                                .fill(fraction >= 1 ? Theme.success : Theme.accent)
                                .frame(width: max(0, geo.size.width * fraction))
                                .animation(.easeOut(duration: 0.25), value: fraction)
                        }
                    }
                    .frame(height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}
