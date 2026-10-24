import SwiftUI
import AppKit

/// Lists every 0-byte file in the scanned library so they can be reviewed and
/// (once the account has delete permission) removed in one go.
struct ZeroByteSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "trash.slash")
                    .foregroundStyle(Theme.warning)
                Text("无效数据").font(Theme.title(15))
                Text("\(state.zeroByteItems.count) 个")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.plain)
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Text("判定规则：0 字节，或非图片文件小于 512 KB。这些文件不可能生成缩略图，删除是不可撤销操作。")
                .font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 16).padding(.bottom, 8)

            Divider().overlay(Theme.stroke)

            if state.zeroByteItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.success)
                    Text("没有无效数据").font(Theme.body(12)).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.zeroByteItems) { item in
                            HStack(spacing: 8) {
                                Button { state.toggleZero(item.id) } label: {
                                    Image(systemName: state.selectedZeroIDs.contains(item.id)
                                          ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 11))
                                        .foregroundStyle(state.selectedZeroIDs.contains(item.id)
                                                         ? Theme.accent : Theme.textFaint)
                                }
                                .buttonStyle(.plain)
                                Text(item.filename)
                                    .font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(item.folderPath)
                                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                                    .lineLimit(1).truncationMode(.head)
                                    .frame(maxWidth: 320, alignment: .trailing)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 16)
                            Divider().overlay(Theme.stroke.opacity(0.5))
                        }
                    }
                }
            }

            Divider().overlay(Theme.stroke)
            HStack(spacing: 10) {
                Button(state.selectedZeroIDs.count == state.zeroByteItems.count ? "取消全选" : "全选") {
                    if state.selectedZeroIDs.count == state.zeroByteItems.count {
                        state.selectedZeroIDs.removeAll()
                    } else {
                        state.selectedZeroIDs = Set(state.zeroByteItems.map(\.id))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim)

                Spacer()

                Button("复制路径") {
                    let text = state.zeroByteItems.map(\.folderPath).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim)

                Button("导出 CSV") { exportCSV() }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim)

                Button {
                    state.deleteSelectedZeroByteFiles()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash").font(.system(size: 10, weight: .bold))
                        Text("删除所选（\(state.selectedZeroIDs.count)）").font(Theme.body(11))
                    }
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(state.canDeleteOnNAS ? Color.red.opacity(0.35) : Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.canDeleteOnNAS ? Color.red : Theme.textFaint)
                .disabled(!state.canDeleteOnNAS || state.selectedZeroIDs.isEmpty)
                .help(state.canDeleteOnNAS ? "从 NAS 永久删除" : "当前账号没有删除权限")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 760, height: 520)
        .background(Theme.background)
        .onAppear { state.collectZeroByteItems() }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "zero-byte-files.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? state.zeroBytesCSV.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
