#if os(iOS)
import SwiftUI
import UIKit

/// In-app viewer / exporter for the always-on diagnostic log.
///
/// The Files-app route is documented here as well: when the app crashes before
/// this screen can be opened, the raw log is still reachable at
/// Documents/iMusicDiagnostics/session.log.
public struct DiagnosticsView: View {
    @State private var preview = "正在读取日志…"
    @State private var shareURL: URL?
    @State private var statusMessage = ""
    @State private var showClearConfirmation = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("导出完整日志 (.txt)", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Label("正在生成导出文件…", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        UIPasteboard.general.string = preview
                        statusMessage = "已复制当前显示的日志"
                    } label: {
                        Label("复制日志到剪贴板", systemImage: "doc.on.doc")
                    }
                    Button {
                        saveToDocuments()
                    } label: {
                        Label("另存一份到「文件」App", systemImage: "folder")
                    }
                } header: {
                    Text("导出")
                } footer: {
                    Text("导出的日志已自动脱敏（token / cookie / 账号标识等会被替换），但仍建议只发给可信的人。")
                }

                Section {
                    Text(DiagnosticLogger.shared.logDirectoryDescription)
                        .textSelection(.enabled)
                    Text("如果 App 一操作就闪退、根本打不开这一页，请直接用「文件」App 按上面的路径取 session.log —— 日志是实时写入磁盘的，崩溃前的最后几行会保留下来。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("无需打开 App 也能取日志")
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ScrollView(.horizontal) {
                        Text(preview)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(minHeight: 220, maxHeight: 420)
                } header: {
                    Text("最近日志（末尾 \(DiagnosticLoggerPreviewLimit.kilobytes) KB）")
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新日志")
                }
            }
            .task { reload() }
            .alert("清空所有诊断日志？", isPresented: $showClearConfirmation) {
                Button("清空", role: .destructive) {
                    DiagnosticLogger.shared.clearLogs()
                    reload()
                    statusMessage = "日志已清空，新的会话已开始记录"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除已保存的日志。清空后可以重新复现一次闪退，再把新日志发出来分析。")
            }
        }
    }

    private func reload() {
        preview = DiagnosticLogger.shared.previewText()
        shareURL = DiagnosticLogger.shared.exportURL()
    }

    private func saveToDocuments() {
        guard let source = DiagnosticLogger.shared.exportURL() else {
            statusMessage = "生成导出文件失败"
            return
        }
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            statusMessage = "无法访问 Documents 目录"
            return
        }
        let directory = documents.appendingPathComponent("iMusicDiagnostics", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
            statusMessage = "已保存到「文件」App → iMusic → iMusicDiagnostics → \(destination.lastPathComponent)"
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

private enum DiagnosticLoggerPreviewLimit {
    static let kilobytes = 120
}
#endif
