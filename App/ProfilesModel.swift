import Foundation
import Observation
import Core
import AppFeature

/// 「配置档案」库的 App 侧协调者。把当前的代理/规则/目录配置存成命名档案、随时载入切换。
///
/// 刻意做成**附加式命名快照**,不改动既有的工作配置 autosave(仍走 `FilePersistenceStore`):
/// 档案是一个可存/取的预设库。「载入」= `resetState` 清干净 + 灌入该档案的 restorationActions
/// (凭据从 Keychain 回填),干净替换而非叠加;下一次 autosave 会把它落进 config.json,自然生效。
@MainActor
@Observable
final class ProfilesModel {
    private(set) var collection = ProfileCollection()
    private let store: Store
    private let profileStore: any ProfileStoring
    private let credentialStore: any CredentialStore

    init(store: Store, profileStore: any ProfileStoring, credentialStore: any CredentialStore) {
        self.store = store
        self.profileStore = profileStore
        self.credentialStore = credentialStore
    }

    /// 启动时载入档案库(只填列表,不动当前工作配置)。
    func loadLibrary() async {
        collection = await profileStore.load()
    }

    /// 把当前状态存成档案:名字已存在则就地更新,否则新增;都设为 active。密码进 Keychain。
    func saveCurrent(as name: String) async {
        let config = PersistedConfiguration(from: store.state)
        var updated = collection
        if updated.profiles.contains(where: { $0.name == name }) {
            updated.updateConfiguration(named: name, to: config)
        } else {
            updated.add(name: name, configuration: config)
        }
        updated.setActive(name: name)
        collection = updated
        await profileStore.save(updated)
        await PersistedConfiguration.saveCredentials(
            from: Array(store.state.proxyServers.values), to: credentialStore
        )
    }

    /// 载入某个档案:reset 当前状态,灌入该档案配置(凭据回填),设为 active。
    func load(name: String) async {
        guard let profile = collection.profiles.first(where: { $0.name == name }) else { return }
        var updated = collection
        updated.setActive(name: name)
        collection = updated
        await profileStore.save(updated)

        store.dispatch(.resetState)
        for action in await profile.configuration.restorationActions(rehydratingCredentialsFrom: credentialStore) {
            store.dispatch(action)
        }
        store.dispatch(.appLaunched) // 重新扫描目录,刷新进程列表
    }

    /// 删除档案(删的是 active 时,active 由集合落到剩下的第一个)。
    func delete(name: String) async {
        var updated = collection
        updated.remove(name: name)
        collection = updated
        await profileStore.save(updated)
    }
}
