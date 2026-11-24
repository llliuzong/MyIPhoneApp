import Foundation
import SwiftUI

@MainActor
struct WorkoutView: View {
    @ObservedObject var store: PullUpStore

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    PullUpSessionView(store: store)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("引体向上")
                                .font(.body.weight(.semibold))
                            Text(store.active == nil ? "按组记录次数" : "训练进行中")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("运动")
        }
    }
}

@MainActor
private struct PullUpSessionView: View {
    @ObservedObject var store: PullUpStore
    @State private var repsInput = ""
    @State private var operationError = ""
    @State private var showOperationError = false
    @FocusState private var isEntryFocused: Bool

    var body: some View {
        Form {
            if !store.isAvailable {
                Text("暂时无法读取训练记录，请重开 App 后再试。")
                    .foregroundStyle(.secondary)
            } else if let workout = store.active {
                trainingSections(workout)
            } else {
                Section {
                    Button("开始训练") { perform { try store.start() } }
                }
                historySection
            }
        }
        .navigationTitle("引体向上")
        .navigationBarTitleDisplayMode(.inline)
        .alert("训练记录操作失败", isPresented: $showOperationError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(operationError)
        }
    }

    private var input: String {
        repsInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var enteredReps: Int? {
        guard let reps = Int(input), reps > 0 else { return nil }
        return reps
    }

    @ViewBuilder
    private func trainingSections(_ workout: PullUpWorkout) -> some View {
        Section("本次训练") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                summary(workout, seconds: workout.elapsed(at: context.date))
            }
        }

        Section("录入第 \(workout.totalSets + 1) 组") {
            TextField("输入本组次数", text: $repsInput)
                .keyboardType(.numberPad)
                .focused($isEntryFocused)
                .accessibilityLabel("本组次数")
            Button("记一组") {
                guard let reps = enteredReps else { return }
                perform {
                    try store.recordSet(reps)
                    clearEntry()
                }
            }
            .disabled(enteredReps == nil)
        }

        if !workout.repsPerSet.isEmpty {
            Section("已记录") {
                ForEach(workout.repsPerSet.indices.reversed(), id: \.self) { index in
                    LabeledContent("第 \(index + 1) 组", value: "\(workout.repsPerSet[index]) 次")
                }
            }
        }

        Section {
            Button(enteredReps == nil ? "结束并保存" : "记入本组并结束") {
                perform {
                    try store.finish(lastSet: enteredReps)
                    clearEntry()
                }
            }
            .disabled(input.isEmpty ? workout.totalSets == 0 : enteredReps == nil)

            if workout.totalSets == 0 {
                Button("取消训练", role: .destructive) {
                    perform {
                        try store.cancelEmptyWorkout()
                        clearEntry()
                    }
                }
            }
        }
    }

    private var historySection: some View {
        Section("训练记录") {
            if store.history.isEmpty {
                Text("暂无训练记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.history) { workout in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(workout.startedAt, format: .dateTime.month().day().hour().minute())
                            .font(.subheadline.weight(.semibold))
                        summary(workout, seconds: workout.durationSeconds ?? 0)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func summary(_ workout: PullUpWorkout, seconds: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                metric("总次数", workout.totalReps.formatted())
                Spacer(minLength: 0)
                metric("总组数", workout.totalSets.formatted())
                Spacer(minLength: 0)
                metric("用时", timeText(seconds))
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                metric("总次数", workout.totalReps.formatted())
                metric("总组数", workout.totalSets.formatted())
                metric("用时", timeText(seconds))
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func timeText(_ total: Int) -> String {
        let minutes = total / 60
        let seconds = total % 60
        if minutes < 60 { return String(format: "%02d:%02d", minutes, seconds) }
        return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
    }

    private func clearEntry() {
        repsInput = ""
        isEntryFocused = false
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            operationError = error.localizedDescription
            showOperationError = true
        }
    }
}
