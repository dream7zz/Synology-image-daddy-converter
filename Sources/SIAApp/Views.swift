import SwiftUI
import AppKit
import AVKit
import SIACore

// MARK: - Root

struct RootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HSplitView {
            SidebarView(state: state)
                .frame(minWidth: 220, idealWidth: 236, maxWidth: 280)

            MainView(state: state)
                .frame(minWidth: 520)

            if state.selectedItem != nil {
                InspectorView(state: state)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear {
            if ProcessInfo.processInfo.environment["SIA_OPEN_QUEUE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    QueueWindowController.shared.show(state: state)
                }
            }
        }
        .sheet(isPresented: $state.showLogin) {
            LoginSheet(state: state) { state.showLogin = false }
        }
        .sheet(isPresented: $state.showSettings) {
            SettingsSheet(state: state) { state.showSettings = false }
        }
        .sheet(isPresented: $state.showZeroByteSheet) {
            ZeroByteSheet(state: state)
        }
        .sheet(isPresented: Binding(
            get: { state.viewingItemID != nil },
            set: { if !$0 { state.viewingItemID = nil } }
        )) {
            if let item = state.items.first(where: { $0.id == state.viewingItemID }) {
                MediaViewer(item: item, state: state) { state.viewingItemID = nil }
            }
        }
    }
}

final class PopoverState: ObservableObject {
    @Published var show = false
}

struct HelpBadge: View {
    let title: String
    let text: String
    @StateObject private var pop = PopoverState()

    var body: some View {
        Button { pop.show.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textFaint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pop.show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.body(12).weight(.semibold))
                Text(text).font(Theme.body(11)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 260)
        }
    }
}

struct ToolButton: View {
    let title: String
    let systemImage: String
    var prominent: Bool = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(prominent ? Theme.accent.opacity(0.16) : Theme.panelRaised)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(prominent ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Theme.accent : Theme.text)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

struct IconButton: View {
    let systemImage: String
    var help: String = ""
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Theme.panelRaised)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountSwitcher
            Divider().overlay(Theme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("文件夹") {
                        HStack(spacing: 6) {
                            Image(systemName: state.allRootsSelected
                                  ? "checkmark.square.fill" : "square")
                                .font(.system(size: 10))
                                .foregroundStyle(state.allRootsSelected
                                                 ? Theme.accent : Theme.textFaint)
                            Text("全选").font(Theme.body(11)).foregroundStyle(Theme.textDim)
                            Spacer()
                            Text("\(state.selectedRootCount)/\(state.rootFolders.count)")
                                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                        }
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !state.isBusy else { return }
                            state.toggleAllRoots()
                        }
                        .help(state.isBusy ? "任务进行中，停止后可更改范围" : "全选 / 全不选")

                        folderRow(path: nil, title: "全部",
                                  total: state.counts.total,
                                  missing: state.counts.missing)
                        ForEach(state.displayTree) { node in
                            FolderTreeRow(node: node, depth: 0, state: state)
                        }
                        if state.displayTree.isEmpty {
                            Text("正在读取根目录…")
                                .font(Theme.body(10)).foregroundStyle(Theme.textFaint)
                        }
                        Button {
                            state.scanSelected()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9, weight: .bold))
                                Text("扫描所选（\(state.selectedPaths.count)）")
                                    .font(Theme.body(11))
                            }
                            .padding(.vertical, 4).padding(.horizontal, 7)
                            .frame(maxWidth: .infinity)
                            .background(state.selectedPaths.isEmpty
                                        ? Theme.panelRaised
                                        : Theme.accent.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(state.selectedPaths.isEmpty ? Theme.textFaint : Theme.accent)
                        .disabled(state.isBusy || state.selectedPaths.isEmpty)
                    }

                    if !state.zeroByteItems.isEmpty {
                        Button {
                            state.collectZeroByteItems()
                            state.showZeroByteSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash.slash").font(.system(size: 9))
                                Text("无效数据").font(Theme.body(11))
                                Spacer()
                                Text("\(state.zeroByteItems.count)")
                                    .font(Theme.mono(9))
                            }
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    group("筛选") {
                        ForEach(AppState.Filter.allCases) { f in
                            filterRow(f)
                        }
                    }

                    group("状态") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(state.phase == .running ? Theme.accent : Theme.textFaint)
                                .frame(width: 6, height: 6)
                            Text(phaseText).font(Theme.body(11)).foregroundStyle(Theme.textDim)
                        }
                        if let job = state.activeJob {
                            Text(job.filename)
                                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                        }
                    }

                    if !state.stageCounts.isEmpty {
                        group("队列") {
                            ForEach(state.stageCounts, id: \.0) { item in
                                HStack {
                                    Text(item.0).font(Theme.body(11)).foregroundStyle(Theme.textDim)
                                    Spacer()
                                    Text("\(item.1)").font(Theme.mono(10)).foregroundStyle(Theme.text)
                                }
                            }
                        }
                    }

                }
                .padding(14)
            }
            Spacer(minLength: 0)
        }
        .background(Theme.panel)
    }

    private var phaseText: String {
        switch state.phase {
        case .idle: return "空闲"
        case .scanning: return "扫描中"
        case .running: return "运行中"
        case .paused: return "已暂停"
        case .finished: return "已完成"
        }
    }

    private var accountSwitcher: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "账号")
                Spacer()
                Button {
                    state.showLogin = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
            }

            ForEach(state.accounts) { account in
                Button {
                    state.select(account)
                } label: {
                    HStack(spacing: 8) {
                        Text(account.initials)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color(hue: account.hue, saturation: 0.55,
                                                            brightness: 0.95)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName)
                                .font(Theme.body(12)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(account.host)
                                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
                        }
                        Spacer()
                        if state.selectedAccountID == account.id {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(state.selectedAccountID == account.id
                                ? Theme.panelRaised : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("登出") { state.logout() }
                    Button("移除账号", role: .destructive) { state.removeSelectedAccount() }
                }
            }

            if state.accounts.isEmpty {
                Text("还没有账号").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(14)
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            content()
        }
    }

    private func folderRow(path: String?, title: String, total: Int, missing: Int) -> some View {
        let active = path.map { state.pathIsSelected($0) } ?? false
        return Button {
            // Clicking the row toggles the tick; there is no separate focus.
            path.map { state.togglePath($0) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: path == nil ? "tray.full" : "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(active ? Theme.accent : Theme.textFaint)
                Text(title).font(Theme.body(11)).lineLimit(1)
                Spacer()
                if missing > 0 {
                    Text("\(missing)").font(Theme.mono(9)).foregroundStyle(Theme.warning)
                }
                Text("\(total)").font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
            }
            .foregroundStyle(active ? Theme.text : Theme.textDim)
            .padding(.vertical, 4).padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Theme.panelRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func filterRow(_ f: AppState.Filter) -> some View {
        let count: Int = {
            switch f {
            case .all: return state.counts.total
            case .ready: return state.counts.ready
            case .missing: return state.counts.missing
            case .invalid: return state.libraryCounts.empty
            case .failed: return state.counts.failed
            }
        }()
        return Button {
            state.filter = f
        } label: {
            HStack {
                Text(f.rawValue).font(Theme.body(12))
                Spacer()
                Text("\(count)").font(Theme.mono(10))
            }
            .foregroundStyle(state.filter == f ? Theme.text : Theme.textDim)
            .padding(.vertical, 5).padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(state.filter == f ? Theme.panelRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FolderTreeRow: View {
    let node: FolderNode
    let depth: Int
    @ObservedObject var state: AppState

    private var isExpanded: Bool { state.expandedFolders.contains(node.id) }
    private var isChecked: Bool { state.pathIsSelected(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if node.children.isEmpty {
                    Spacer().frame(width: 12)
                } else {
                    Button {
                        if isExpanded { state.expandedFolders.remove(node.id) }
                        else { state.expandedFolders.insert(node.id) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                            .frame(width: 12, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // The whole row is the hit target, not just the small box.
                HStack(spacing: 5) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10))
                        .foregroundStyle(isChecked ? Theme.accent : Theme.textFaint)
                    Image(systemName: node.children.isEmpty ? "folder" : "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isChecked ? Theme.accent.opacity(0.8) : Theme.textFaint)
                    Text(node.name)
                        .font(Theme.body(11))
                        .foregroundStyle(isChecked ? Theme.text : Theme.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if node.missing > 0 {
                        Text("\(node.missing)")
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.warning)
                    }
                    if node.total > 0 {
                        Text("\(node.total)")
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !state.isBusy else { return }
                    state.togglePath(node.id)
                }
                .help(state.isBusy ? "任务进行中，停止后可更改范围" : "点击整行即勾选/取消")
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .padding(.leading, CGFloat(depth) * 10)
            .background(isChecked ? Theme.accent.opacity(0.06) : Color.clear)

            if isExpanded {
                ForEach(node.children) { child in
                    FolderTreeRow(node: child, depth: depth + 1, state: state)
                }
            }
        }
    }
}

// MARK: - Main

struct MainView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Theme.stroke)
            if state.items.isEmpty {
                emptyState
            } else if state.viewMode == .grid {
                GridView(state: state)
            } else {
                TableView(state: state)
            }
        }
        .background(Theme.background)
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            // Row 1: actions. Only the primary two keep text labels.
            HStack(spacing: 8) {
                ToolButton(title: "扫描所选", systemImage: "arrow.clockwise") {
                    state.scanSelected()
                }
                .disabled(state.isBusy)
                ToolButton(title: "开始", systemImage: "play.fill", prominent: true) {
                    state.start()
                }
                    .disabled(state.isBusy || state.items.isEmpty)
                IconButton(systemImage: "pause.fill", help: "暂停") { state.pause() }
                    .disabled(state.phase != .running)
                IconButton(systemImage: "playpause.fill", help: "继续") { state.resume() }
                    .disabled(state.phase != .paused)
                IconButton(systemImage: "stop.fill", help: "停止") { state.stop() }
                    .disabled(!state.isBusy)
                if state.counts.failed > 0 {
                    ToolButton(title: "重试 \(state.counts.failed)", systemImage: "arrow.counterclockwise") {
                        state.retryAllFailed()
                    }
                    .disabled(state.isBusy)
                }
                Spacer(minLength: 8)
                ToolButton(title: "队列", systemImage: "list.bullet.rectangle") {
                    QueueWindowController.shared.show(state: state)
                }
                IconButton(systemImage: "trash.slash", help: "无效数据") {
                    state.collectZeroByteItems()
                    state.showZeroByteSheet = true
                }
                IconButton(systemImage: "gearshape.fill", help: "设置") { state.showSettings = true }
            }

            // Row 2: find + view mode, always on its own line so nothing wraps.
            HStack(spacing: 8) {
                TextField("搜索文件或目录", text: $state.search)
                    .textFieldStyle(.plain)
                    .font(Theme.body(11))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer(minLength: 8)
                Picker("", selection: $state.viewMode) {
                    ForEach(AppState.ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                Text("\(state.visibleItems.count) 项")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
            }

            progressStrip
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var statusText: String {
        switch state.phase {
        case .idle: return "空闲"
        case .scanning: return "扫描中"
        case .running: return "运行中"
        case .paused: return "已暂停"
        case .finished: return "已完成"
        }
    }

    private var progressStrip: some View {
        let p = state.overallProgress
        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(state.isBusy ? Theme.accent : Theme.textFaint)
                    .frame(width: 5, height: 5)
                Text(state.phase == .scanning ? "扫描中" : statusText)
                    .font(Theme.body(10))
                    .fontWeight(.medium)
                    .foregroundStyle(state.isBusy ? Theme.accent : Theme.textDim)
                    .lineLimit(1)
            }
            .frame(minWidth: 96, alignment: .leading)

            if state.phase == .scanning {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
                    .frame(width: 150).tint(Theme.accent)
                Text(state.scanStatus ?? "准备扫描…")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                Text("\(state.items.count) 项")
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.text)
            } else {
                if let job = state.activeJob {
                    Text(job.filename)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                        .help(job.filename)
                }

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panelRaised)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.85), Theme.accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, 150 * p.fraction))
                        .animation(.easeOut(duration: 0.25), value: p.fraction)
                }
                .frame(width: 150, height: 4)

                Text("\(p.done)/\(p.total)")
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("范围 \(state.scopeLabel)")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textFaint)
            if state.selectedPaths.isEmpty {
                Text("还没有勾选文件夹").font(Theme.title(15)).foregroundStyle(Theme.text)
                Text("在左侧勾选要查看的文件夹，网格只显示勾选范围内的内容")
                    .font(Theme.body(11)).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            } else if state.items.isEmpty {
                Text("还没有扫描").font(Theme.title(15)).foregroundStyle(Theme.text)
                Text("点「扫描所选」读取勾选文件夹的内容")
                    .font(Theme.body(11)).foregroundStyle(Theme.textDim)
            } else {
                Text("没有符合条件的内容").font(Theme.title(15)).foregroundStyle(Theme.text)
                Text("当前筛选或搜索没有匹配到勾选范围内的文件")
                    .font(Theme.body(11)).foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Grid

struct GridView: View {
    @ObservedObject var state: AppState
    @ObservedObject var thumbs: ThumbnailStore

    init(state: AppState) {
        self.state = state
        self.thumbs = state.thumbnailStore
    }

    private let minWidth: CGFloat = 176
    private let spacing: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            // Compute the column count from the available width and let each
            // column flex: fixed-width columns left uneven gutters and big
            // empty bands on both sides when the window was wider.
            let usable = max(geo.size.width - spacing * 2, minWidth)
            let count = max(2, Int((usable + spacing) / (minWidth + spacing)))
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing),
                                count: count)

            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(state.visibleItems) { item in
                        ItemCard(item: item, state: state, thumbs: thumbs)
                            .onTapGesture { state.selectedItemID = item.id }
                            .onTapGesture(count: 2) { state.openViewer(item.id) }
                    }
                }
                .padding(spacing)
            }
        }
    }
}

struct ItemCard: View {
    let item: PhotoItem
    @ObservedObject var state: AppState
    @ObservedObject var thumbs: ThumbnailStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.panelRaised)
                GeometryReader { box in
                    if let img = thumbs.images[item.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: box.size.width, height: box.size.height)
                            .clipped()
                            .transition(.opacity)
                    } else if thumbs.failed.contains(item.id) {
                        Image(systemName: "film")
                            .foregroundStyle(Theme.textFaint)
                            .frame(width: box.size.width, height: box.size.height)
                    } else {
                        skeleton
                            .frame(width: box.size.width, height: box.size.height)
                    }
                }
                badge
            }
            .frame(height: 112)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(Theme.body(11)).foregroundStyle(Theme.text).lineLimit(1)
                // Where the file lives: the grid mixes many folders, and the
                // filename alone rarely says which one.
                Text(item.folderPath)
                    .font(Theme.mono(9)).foregroundStyle(Theme.textDim)
                    .lineLimit(1).truncationMode(.middle)
                    .help(item.folderPath)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                        .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    if let codec = item.codec {
                        Text(codec).font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    Text(stageText).font(Theme.mono(9)).foregroundStyle(stageColor)
                }
                if let job = state.jobs[item.id],
                   job.stage == .fetching || job.stage == .converting || job.stage == .uploading {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.stroke)
                            Capsule().fill(Theme.accent)
                                .frame(width: max(2, geo.size.width * job.progress))
                        }
                    }
                    .frame(height: 2)
                }
            }
            .padding(8)
        }
        .card(selected: state.selectedItemID == item.id)
        .contextMenu {
            Button("重试这一项") { state.retry(itemID: item.id) }
                .disabled(state.isBusy)
            Button("查看详情") { state.selectedItemID = item.id }
        }
        .task(id: thumbs.generation) { thumbs.load(item) }
    }

    private var skeleton: some View {
        ZStack {
            LinearGradient(colors: [Theme.panelRaised, Theme.stroke.opacity(0.6), Theme.panelRaised],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if thumbs.failed.contains(item.id) {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 16, weight: .light))
                    Text("无缩略图").font(Theme.mono(9))
                }
                .foregroundStyle(Theme.textFaint)
            } else {
                ProgressView().scaleEffect(0.5)
            }
        }
    }

    /// Only terminal/exceptional states get a badge. Missing-size detail lives
    /// in one place (the status line) so it never appears twice.
    private var badge: some View {
        Group {
            if state.isReady(item) || state.jobs[item.id]?.stage == .done {
                Pill(text: "READY", color: Theme.success, filled: true)
            } else if state.jobs[item.id]?.stage == .failed {
                Pill(text: "FAILED", color: Theme.danger, filled: true)
            }
        }
        .padding(6)
    }

    /// e.g. "缺 xl" or "缺 m、sm" or "无封面" — names the sizes, not a count.
    private var missingLabel: String {
        if item.isInvalid { return "无效数据 · 无法处理" }
        let missing = ["sm", "m", "xl"].filter { item.sizeStates[$0] != "ready" }
        if state.isReady(item) { return "已有缩略图" }
        if missing.count == 3 { return "无封面" }
        if missing.isEmpty { return "已有缩略图" }
        return "缺 " + missing.joined(separator: "、")
    }

    private var stageText: String {
        guard let st = state.jobs[item.id]?.stage else {
            return state.isReady(item) ? "已有缩略图" : missingLabel
        }
        // An item can show a picture and still be queued: it is missing a size.
        if st == .pending, !state.isReady(item) { return "排队 · \(missingLabel)" }
        switch st {
        case .pending: return "排队"
        case .fetching: return "读取"
        case .converting: return "抽帧"
        case .readyToUpload: return "待传"
        case .uploading: return "上传"
        case .done: return "完成"
        case .skipped: return "跳过"
        case .blocked: return "阻塞"
        case .failed: return "失败"
        case .cancelled: return "取消"
        }
    }

    private var stageColor: Color {
        guard let st = state.jobs[item.id]?.stage else {
            return item.state == .ready ? Theme.success : Theme.textFaint
        }
        switch st {
        case .done: return Theme.success
        case .failed, .blocked: return Theme.danger
        case .fetching, .converting, .uploading: return Theme.accent
        default: return Theme.textFaint
        }
    }
}

// MARK: - Table

struct TableView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Table(state.visibleItems) {
            TableColumn("文件") { (item: PhotoItem) in
                Text(item.filename).font(Theme.body(11)).lineLimit(1)
            }.width(min: 200)

            TableColumn("大小") { (item: PhotoItem) in
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                    .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
            }.width(70)

            TableColumn("编码") { (item: PhotoItem) in
                Text(item.codec ?? "-").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
            }.width(50)

            TableColumn("目录") { (item: PhotoItem) in
                Text(item.folderPath).font(Theme.mono(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }.width(min: 140)

            TableColumn("状态") { (item: PhotoItem) in
                HStack(spacing: 5) {
                    if let st = state.jobs[item.id]?.stage {
                        Text(stageName(st)).font(Theme.mono(10)).foregroundStyle(Theme.accent)
                        if st == .fetching || st == .converting || st == .uploading {
                            ProgressView(value: state.progress(for: item.id))
                                .frame(width: 50)
                        }
                    } else {
                        Text(item.state == .ready ? "已有缩略图"
                             : ["sm", "m", "xl"].filter { item.sizeStates[$0] != "ready" }
                                 .joined(separator: "、") + " 缺失")
                            .font(Theme.mono(10))
                            .foregroundStyle(item.state == .ready ? Theme.success : Theme.warning)
                    }
                }
            }.width(120)
        }
        .onTapGesture {}
    }

    private func stageName(_ s: JobStage) -> String {
        switch s {
        case .pending: return "排队"
        case .fetching: return "读取"
        case .converting: return "抽帧"
        case .readyToUpload: return "待传"
        case .uploading: return "上传"
        case .done: return "完成"
        case .skipped: return "跳过"
        case .blocked: return "阻塞"
        case .failed: return "失败"
        case .cancelled: return "取消"
        }
    }
}

// MARK: - Inspector

final class InspectorModel: ObservableObject {
    @Published var xl: NSImage?
    @Published var m: NSImage?
    @Published var sm: NSImage?
}

struct InspectorView: View {
    @ObservedObject var state: AppState
    @ObservedObject var thumbs: ThumbnailStore
    @StateObject private var local = InspectorModel()

    init(state: AppState) {
        self.state = state
        self.thumbs = state.thumbnailStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item = state.selectedItem {
                HStack {
                    SectionLabel(text: "预览")
                    Spacer()
                    Text(item.state == .ready ? "已有缩略图" : "缺失")
                        .font(Theme.mono(9))
                        .foregroundStyle(item.state == .ready ? Theme.success : Theme.warning)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.panelRaised)
                    if let img = local.xl ?? thumbs.images[item.id] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if thumbs.failed.contains(item.id) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 22, weight: .light))
                            Text("NAS 上没有这张图的缩略图").font(Theme.body(10))
                        }
                        .foregroundStyle(Theme.textFaint)
                    } else {
                        ProgressView().scaleEffect(0.6)
                    }
                }
                .frame(height: 188)

                Text(item.filename).font(Theme.body(12)).lineLimit(2)
                    .foregroundStyle(Theme.text)

                SectionLabel(text: "试印")
                HStack(spacing: 8) {
                    proof("xl", local.xl, item)
                    proof("m", local.m, item)
                    proof("sm", local.sm, item)
                }

                SectionLabel(text: "阶段")
                timeline(for: item)

                SectionLabel(text: "信息")
                VStack(alignment: .leading, spacing: 4) {
                    meta("目录", item.folderPath)
                    meta("编码", item.codec ?? "-")
                    meta("大小", ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                    if let w = item.width, let h = item.height { meta("分辨率", "\(w)×\(h)") }
                    meta("单元", "\(item.id)")
                    meta("三档", ["sm", "m", "xl"].map { size in
                        let ok = item.hasThumbnails || item.sizeStates[size] == "ready"
                        return "\(size):\(ok ? "有" : "缺")"
                    }.joined(separator: "  "))
                }

                HStack(spacing: 8) {
                    ToolButton(title: item.type.hasPrefix("video") ? "播放" : "查看",
                               systemImage: "play.rectangle", prominent: true) {
                        state.openViewer(item.id)
                    }
                    ToolButton(title: "重试", systemImage: "arrow.clockwise") {
                        state.retry(itemID: item.id)
                    }
                    .disabled(state.isBusy || item.state == .ready)
                    Spacer()
                }
                .padding(.top, 2)

                Spacer()
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textFaint)
                    Text("选择一项查看详情")
                        .font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14)
        .background(Theme.panel)
        .task(id: state.selectedItemID) {
            local.xl = nil; local.m = nil; local.sm = nil
            guard let item = state.selectedItem else { return }
            let key = item.cacheKey
            let store = thumbs
            Task.detached(priority: .userInitiated) {
                let a = await store.image(id: item.id, cacheKey: key, size: .xl)
                let b = await store.image(id: item.id, cacheKey: key, size: .m)
                let c = await store.image(id: item.id, cacheKey: key, size: .sm)
                await MainActor.run {
                    local.xl = a
                    local.m = b
                    local.sm = c
                }
            }
        }
    }

    private func proof(_ label: String, _ image: NSImage?, _ item: PhotoItem) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Theme.panelRaised)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Text(label).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
            }
            .frame(width: 74, height: 52)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke))
            Text(label).font(Theme.mono(8)).foregroundStyle(Theme.textFaint)
        }
    }

    private func timeline(for item: PhotoItem) -> some View {
        let stage = state.jobs[item.id]?.stage
        let steps: [(String, Bool, Bool)] = [
            ("读取", stage == .fetching || stage == .converting || stage == .uploading || stage == .done,
             stage == .fetching),
            ("抽帧", stage == .converting || stage == .uploading || stage == .done, stage == .converting),
            ("上传", stage == .uploading || stage == .done, stage == .uploading),
            ("完成", stage == .done, false),
        ]
        return HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(step.2 ? Theme.accent : (step.1 ? Theme.success : Theme.stroke))
                        .frame(width: 6, height: 6)
                    Text(step.0)
                        .font(Theme.mono(9))
                        .foregroundStyle(step.1 || step.2 ? Theme.textDim : Theme.textFaint)
                }
                if step.0 != "完成" {
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                }
            }
        }
    }

    private func meta(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                .frame(width: 44, alignment: .leading)
            Text(v).font(Theme.mono(10)).foregroundStyle(Theme.textDim).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Login

final class LoginForm: ObservableObject {
    @Published var displayName = ""
    @Published var host = ""
    @Published var username = ""
    @Published var password = ""
    @Published var error: String?
    @Published var busy = false
}

struct LoginSheet: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void
    @StateObject private var form = LoginForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加账号").font(Theme.title(16)).foregroundStyle(Theme.text)

            field("显示名称", $form.displayName, "My NAS")
            field("地址", $form.host, "host:5001")
            field("账号", $form.username, "username")
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "密码")
                SecureField("", text: $form.password)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let error = form.error {
                Text(error).font(Theme.body(10)).foregroundStyle(Theme.danger)
            }

            HStack {
                Spacer()
                Button("取消") { onClose() }
                Button(form.busy ? "验证中…" : "测试并登录") {
                    form.busy = true
                    form.error = nil
                    Task {
                        let err = await state.addAccount(displayName: form.displayName,
                                                         host: form.host,
                                                         username: form.username,
                                                         password: form.password)
                        await MainActor.run {
                            form.busy = false
                            form.error = err
                            if err == nil { onClose() }
                        }
                    }
                }
                .disabled(form.busy || form.host.isEmpty || form.username.isEmpty || form.password.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(6)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}


// MARK: - Settings

struct SettingsSheet: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置").font(Theme.title(16)).foregroundStyle(Theme.text)
                Spacer()
                if let a = state.account {
                    Text("\(a.username) @ \(a.host)")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
            }

            section("处理") {
                row("失败重试次数") {
                    TextField("", value: $state.options.retries, format: .number)
                        .frame(width: 50).textFieldStyle(.roundedBorder)
                }
                row("整包下载阈值") {
                    TextField("", value: Binding(
                        get: { state.options.maxBytesForFullDownload / 1_000_000 },
                        set: { state.options.maxBytesForFullDownload = $0 * 1_000_000 }
                    ), format: .number)
                    .frame(width: 70).textFieldStyle(.roundedBorder)
                    Text("MB").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
            }

            section("写入") {
                Text("生成后自动回传。只会新增三档缩略图，不会修改或删除原文件。")
                    .font(Theme.body(10)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("取帧位置固定在片头后 0.3 秒（与原版助手一致，无时间参数）。")
                    .font(Theme.body(10)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }


            section("账号") {
                HStack(spacing: 10) {
                    Button("登出（保留数据）") { state.logout(); onClose() }
                    Button("移除账号", role: .destructive) { state.removeSelectedAccount(); onClose() }
                    Spacer()
                }
                .font(Theme.body(11))
            }

            Spacer()

            HStack {
                Button("恢复默认") {
                    let keepUpload = state.options.autoUpload
                    state.options = EngineOptions()
                    state.options.autoUpload = keepUpload
                }
                Spacer()
                Button("完成") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 470)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack {
            Text(title).font(Theme.body(11)).foregroundStyle(Theme.textDim).frame(width: 96, alignment: .leading)
            content()
            Spacer()
        }
    }
}


// MARK: - Viewer

final class ViewerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var photo: NSImage?
    @Published var error: String?
    @Published var loading = true
}

struct MediaViewer: View {
    let item: PhotoItem
    @ObservedObject var state: AppState
    let onClose: () -> Void
    @StateObject private var model = ViewerModel()

    private var isVideo: Bool { item.type.hasPrefix("video") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isVideo ? "play.rectangle" : "photo")
                    .foregroundStyle(Theme.accent)
                Text(item.filename).font(Theme.body(13)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(Theme.panel)

            Divider().overlay(Theme.stroke)

            ZStack {
                Color.black
                if let error = model.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24)).foregroundStyle(Theme.warning)
                        Text(error).font(Theme.body(11)).foregroundStyle(Theme.textDim)
                    }
                } else if model.loading {
                    ProgressView().scaleEffect(0.8)
                } else if let player = model.player {
                    VideoPlayer(player: player)
                } else if let photo = model.photo {
                    Image(nsImage: photo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                }
            }
            .frame(minWidth: 720, minHeight: 460)
        }
        .frame(width: 860, height: 560)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .task {
            if isVideo {
                guard let player = state.makePlayer(for: item.id) else {
                    model.error = "未连接，无法播放"
                    model.loading = false
                    return
                }
                player.play()
                model.player = player
                model.loading = false
            } else {
                guard let client = state.client else {
                    model.error = "未连接"
                    model.loading = false
                    return
                }
                Task.detached(priority: .userInitiated) {
                    let result = try? client.raw(api: "SYNO.FotoTeam.Download",
                                                 version: "1",
                                                 method: "download",
                                                 params: ["item_id": "[\(item.id)]"],
                                                 rangeHeader: nil)
                    await MainActor.run {
                        model.loading = false
                        if let data = result?.0, let img = NSImage(data: data) {
                            model.photo = img
                        } else {
                            model.error = "无法加载原图"
                        }
                    }
                }
            }
        }
        .onDisappear { model.player?.pause() }
    }
}
