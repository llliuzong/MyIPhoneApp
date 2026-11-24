import SwiftUI

@MainActor
struct TodoView: View {
    @ObservedObject var store: TodoStore
    @State private var editor: EditorRoute?
    @State private var operationError = ""
    @State private var showOperationError = false

    var body: some View {
        NavigationStack {
            List {
                if !store.isAvailable {
                    emptyMessage("暂时无法读取待办", detail: "请重新打开 App 后再试。", icon: "exclamationmark.circle")
                } else if store.items.isEmpty {
                    emptyMessage("还没有待办", detail: "点右上角的加号，添加第一条。", icon: "checklist")
                } else {
                    section("待处理", items: store.pending)
                    section("已完成", items: store.completed)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("待办")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editor = EditorRoute(item: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增待办")
                    .disabled(!store.isAvailable)
                }
            }
            .sheet(item: $editor) { route in
                TodoEditor(item: route.item, store: store)
            }
            .alert("待办操作失败", isPresented: $showOperationError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(operationError)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [TodoItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    row(item)
                }
            } header: {
                Text("\(title) · \(items.count)")
            }
        }
    }

    private func row(_ item: TodoItem) -> some View {
        HStack(spacing: 4) {
            Button {
                perform { try store.toggleCompletion(id: item.id) }
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? Color.secondary : Color.accentColor)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.isCompleted ? "恢复待办：\(item.title)" : "完成待办：\(item.title)")

            Button {
                editor = EditorRoute(item: item)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.body.weight(.semibold))
                            .strikethrough(item.isCompleted)
                            .foregroundStyle(item.isCompleted ? Color.secondary : Color.primary)
                        if !item.notes.isEmpty {
                            Text(item.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PriorityBadge(priority: item.priority, isCompleted: item.isCompleted)
                }
                .multilineTextAlignment(.leading)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("编辑待办")
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                perform { try store.delete(id: item.id) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func emptyMessage(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            operationError = error.localizedDescription
            showOperationError = true
        }
    }

    private struct EditorRoute: Identifiable {
        let id = UUID()
        let item: TodoItem?
    }
}

@MainActor
private struct TodoEditor: View {
    let item: TodoItem?
    let store: TodoStore
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    @State private var priority: TodoPriority
    @State private var saveError = ""
    @State private var showSaveError = false

    init(item: TodoItem?, store: TodoStore) {
        self.item = item
        self.store = store
        _title = State(initialValue: item?.title ?? "")
        _notes = State(initialValue: item?.notes ?? "")
        _priority = State(initialValue: item?.priority ?? .p1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题（必填）") {
                    TextField("例如：提交周报", text: $title)
                        .accessibilityLabel("标题，必填")
                }
                Section("优先级") {
                    ForEach(TodoPriority.allCases) { level in
                        Button {
                            priority = level
                        } label: {
                            HStack(spacing: 12) {
                                PriorityBadge(priority: level)
                                    .accessibilityHidden(true)
                                Text(level.label)
                                Spacer()
                                if priority == level {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .foregroundStyle(Color.primary)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(level.rawValue)，\(level.label)优先级")
                        .accessibilityAddTraits(priority == level ? .isSelected : [])
                    }
                }
                Section("备注（选填）") {
                    TextField("补充说明", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityLabel("备注，选填")
                }
            }
            .navigationTitle(item == nil ? "新增待办" : "编辑待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("无法保存待办", isPresented: $showSaveError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(saveError)
            }
        }
    }

    private func save() {
        do {
            try store.save(id: item?.id, title: title, notes: notes, priority: priority)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            showSaveError = true
        }
    }
}

private struct PriorityBadge: View {
    let priority: TodoPriority
    var isCompleted = false

    var body: some View {
        Text(priority.rawValue)
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(!isCompleted && priority == .p1 ? Color.black : Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("\(priority.rawValue)，\(priority.label)优先级")
    }

    private var background: Color {
        if isCompleted { return Color(red: 0.35, green: 0.38, blue: 0.43) }
        switch priority {
        case .p0: return Color(red: 0.72, green: 0.13, blue: 0.14)
        case .p1: return Color(red: 0.98, green: 0.78, blue: 0.20)
        case .p2: return Color(red: 0.11, green: 0.39, blue: 0.24)
        }
    }
}
