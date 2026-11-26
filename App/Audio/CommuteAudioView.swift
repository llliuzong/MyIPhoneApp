import SwiftUI

@MainActor
struct CommuteAudioView: View {
    @ObservedObject var audio: CommuteAudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var browse: CommuteListening = .podcast
    @State private var draftClientID = ""

    var body: some View {
        NavigationStack {
            Form {
                if let item = audio.nowPlaying {
                    Section("正在收听") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text(item.author).font(.subheadline).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(audio.isPlaying ? "暂停" : "继续") { audio.toggle() }
                            Spacer()
                            Button("下一条") { audio.next() }
                        }
                        .buttonStyle(.borderless)
                        if let source = item.source {
                            Link(item.kind == .music ? "在 Jamendo 查看" : "查看节目来源", destination: source)
                        }
                    }
                }
                if let error = audio.playbackError {
                    Text(error).foregroundStyle(.secondary)
                }

                Section("通勤自动播放") {
                    modePicker("上班", selection: $audio.workMode)
                    modePicker("回家", selection: $audio.homeMode)
                }

                Section {
                    Picker("内容类型", selection: $browse) {
                        Text("播客").tag(CommuteListening.podcast)
                        Text("音乐").tag(CommuteListening.music)
                    }
                    .pickerStyle(.segmented)
                }

                if browse == .music {
                    Section {
                        TextField("Jamendo Client ID", text: $draftClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存 Client ID") {
                            audio.setClientID(draftClientID)
                            Task { await audio.refresh(.music, force: true) }
                        }
                        .disabled(draftClientID.trimmingCharacters(in: .whitespacesAndNewlines) == audio.clientID)
                        Link("Jamendo 开发者平台", destination: URL(string: "https://developer.jamendo.com/v3.0")!)
                    } header: {
                        Text("音乐榜单")
                    } footer: {
                        Text("使用 Jamendo 独立音乐周榜。填一次 Client ID 即可自动更新。")
                    }
                }

                Section(browse == .music ? "Jamendo 热门音乐" : "津津乐道 · 最新节目") {
                    if audio.loading.contains(browse) {
                        ProgressView("正在更新")
                    } else if let error = audio.catalogErrors[browse] {
                        Text(error).foregroundStyle(.secondary)
                    }
                    ForEach(audio.items(for: browse)) { item in
                        Button {
                            audio.play(item)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(item.author).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: audio.nowPlaying?.id == item.id && audio.isPlaying ? "waveform" : "play.circle")
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !audio.loading.contains(browse), browse != .music || !audio.clientID.isEmpty {
                        Button("立即刷新") {
                            Task { await audio.refresh(browse, force: true) }
                        }
                    }
                }
            }
            .navigationTitle("通勤音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task(id: browse) { await audio.refresh(browse) }
            .onAppear { draftClientID = audio.clientID }
            .onChange(of: audio.workMode) { mode in Task { await audio.refresh(mode) } }
            .onChange(of: audio.homeMode) { mode in Task { await audio.refresh(mode) } }
        }
    }

    private func modePicker(_ title: String, selection: Binding<CommuteListening>) -> some View {
        Picker(title, selection: selection) {
            ForEach(CommuteListening.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
    }
}
