import SwiftUI
import AppFeature

/// 「配置档案」面板:把当前配置存成命名档案,列出已存档案并支持载入/删除。
/// 对标 Proxifier 的多 profile。UI 只读 `model.collection`、调 model 上的异步操作。
struct ProfilesPaneView: View {
    var model: ProfilesModel

    @State private var newName = ""

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配置档案")
                .font(.headline)
            Text("把当前的代理服务器 / 规则 / 目录配置存成命名档案，随时载入切换。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.collection.profiles.isEmpty {
                Text("还没有档案。用下面的「存为新档案」把当前配置存一份。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List(model.collection.profiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: model.collection.activeName == profile.name
                            ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.collection.activeName == profile.name
                                ? Color.accentColor : Color.secondary)
                        Text(profile.name)
                        Spacer()
                        Button("载入") { Task { await model.load(name: profile.name) } }
                        Button("删除", role: .destructive) { Task { await model.delete(name: profile.name) } }
                    }
                }
            }

            Divider()

            HStack {
                TextField("新档案名（同名则更新那个档案）", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button("存为新档案") {
                    let name = trimmedName
                    Task {
                        await model.saveCurrent(as: name)
                        newName = ""
                    }
                }
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
    }
}
