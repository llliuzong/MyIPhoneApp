import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var logger: AppLogger
    @State private var count = 0
    @State private var showCopied = false

    var body: some View {
        NavigationStack {
            List {
                Section("当前计数") {
                    Text(count, format: .number)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .accessibilityLabel("当前计数：\(count)")
                    Button("点击 +1", action: increment)
                    Button("重置", action: reset)
                }

                Section("应用信息") {
                    LabeledContent("版本", value: logger.version)
                    LabeledContent("构建编号", value: logger.build)
                }

                Section("调试日志") {
                    Button("复制日志") {
                        UIPasteboard.general.string = logger.exportText
                        showCopied = true
                    }

                    ForEach(logger.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.message)
                            HStack {
                                Text(entry.date, style: .time)
                                Text(entry.level.rawValue)
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("我的第一个 iPhone App")
            .navigationBarTitleDisplayMode(.inline)
            .alert("日志已复制", isPresented: $showCopied) {
                Button("好", role: .cancel) {}
            }
        }
    }

    private func increment() {
        guard count < Int.max else {
            logger.record("计数已达到上限", level: .error)
            return
        }
        count += 1
        logger.record("点击 +1，当前计数：\(count)")
    }

    private func reset() {
        count = 0
        logger.record("重置计数")
    }
}
