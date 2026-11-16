import Foundation

/// 同意前讀到的主機狀態。
public struct CodexLauncherInspection: Sendable, Equatable {
    /// 會以哪個主機使用者安裝(同意畫面要說明)。
    public var user: String
    public var isInstalled: Bool

    public init(user: String, isInstalled: Bool) {
        self.user = user
        self.isInstalled = isInstalled
    }
}

public enum CodexLauncherError: Error, Equatable {
    /// `~/.local/bin/codex` 已經是別的檔案(例如使用者把 Codex 裝在那裡):不覆蓋。
    case codexAlreadyThere
}

/// Codex 啟動器的主機端(行為規格 §4.2「Session 回報」,ADR-0002 的寫入例外)。【未實測】
///
/// Codex 的共用 app server 不在 herdr 的 pane 裡啟動，會失去 pane 身分，herdr 的 Codex integration 就無法回報
/// session。經使用者同意後在 `~/.local/bin/codex` 放一個 POSIX sh 啟動器：在 herdr pane 裡執行時，把
/// `HERDR_ENV`、`HERDR_PANE_ID`、`HERDR_SOCKET_PATH` 以 `-c shell_environment_policy.set.<名稱>="<值>"` 交給
/// PATH 上真正的 Codex(值是 TOML 字串;Codex 的 `-c` 以 TOML 解析值),其他參數原樣接在後面。
///
/// - 不覆蓋：`~/.local/bin/codex` 已存在且不是 Purrdr 裝的 → `CodexLauncherError.codexAlreadyThere`。
/// - `~/.local`、`~/.local/bin` 不存在時由安裝建立;還原時空了就移除，主機回到安裝前(`ReversibleHostWrite`)。
/// - 要生效,`~/.local/bin` 必須在使用者 shell 的 PATH 裡、排在真正的 Codex 之前(畫面上說明)。
///
/// herdr 0.9.5 的 Codex integration 在共用 app server 下是否仍需要這個啟動器，行為規格 §13 列為待實測。
/// 依行為規格的描述與 openai/codex 原始碼(`-c` 的解析、`shell_environment_policy.set`)撰寫，本機沒有 Codex 可驗證。
public struct CodexLauncherHost: Sendable {
    public static let launcherPath: HostPath = ".local/bin/codex"
    public static let feature = HostWriteFeature(id: "codex-launcher", userFiles: [launcherPath], createsParentDirectories: true)

    let write: ReversibleHostWrite

    public init(channel: any HostChannel) {
        write = ReversibleHostWrite(channel: channel, feature: Self.feature)
    }

    /// 同意前的檢查：能不能安裝(不覆蓋別的 Codex)、會以哪個使用者安裝。
    public func inspect() async throws -> CodexLauncherInspection {
        let inspection = try await write.inspect()
        try Self.checkLauncherPath(in: inspection)
        return CodexLauncherInspection(user: inspection.read.user, isInstalled: inspection.isInstalled)
    }

    /// 安裝(重新讀取，以最新狀態為準;讀取後被改過就整批不寫)。
    public func install() async throws {
        try await write.install { inspection in
            try Self.checkLauncherPath(in: inspection)
            return HostWritePlan(userFiles: [Self.launcherPath: Data(Self.launcherScript.utf8)], ownFiles: [:], executableUserFiles: [Self.launcherPath])
        }
    }

    /// 移除啟動器與安裝時建立的資料夾。使用者後來把 `~/.local/bin/codex` 換成自己的就保留它。
    public func restore() async throws {
        try await write.restore { _, current, _ in current }
    }

    /// 啟動器的位置必須是空的，或是 Purrdr 先前裝的(有安裝紀錄)。
    static func checkLauncherPath(in inspection: HostWriteInspection) throws {
        switch inspection.read[launcherPath] ?? .missing {
        case .missing, .missingDirectory:
            return
        case .file:
            guard inspection.journal?.entry(for: launcherPath) != nil else { throw CodexLauncherError.codexAlreadyThere }
        case .notRegularFile, .unreadable, .tooLarge:
            throw CodexLauncherError.codexAlreadyThere
        }
    }

    /// 啟動器。找 PATH 上「不是自己」的 codex(跳過 `~/.local/bin` 與指向同一檔案的路徑),找不到就 exit 127。
    static let launcherScript = #"""
        #!/bin/sh
        # Purrdr 的 Codex 啟動器：由 Purrdr app 安裝，在 app 移除「Codex 啟動器」就會還原。
        # 在 herdr 的 pane 裡執行時，把 pane 身分交給 Codex(共用 app server 才能回報 session),其餘參數原樣傳下去。
        self_dir="$HOME/.local/bin"
        real=
        old_ifs=$IFS
        IFS=:
        set -f
        for d in $PATH; do
          case $d in
            ''|"$self_dir"|"$self_dir/") continue ;;
          esac
          if [ -f "$d/codex" ] && [ -x "$d/codex" ] && ! [ "$d/codex" -ef "$self_dir/codex" ]; then
            real="$d/codex"
            break
          fi
        done
        set +f
        IFS=$old_ifs
        if [ -z "$real" ]; then
          echo "codex: Purrdr's Codex launcher couldn't find Codex on PATH." >&2
          exit 127
        fi
        toml() {
          printf '%s' "$1" | sed -e 's/[\\"]/\\&/g'
        }
        if [ -n "${HERDR_PANE_ID:-}" ]; then
          if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
            set -- -c "shell_environment_policy.set.HERDR_SOCKET_PATH=\"$(toml "$HERDR_SOCKET_PATH")\"" "$@"
          fi
          set -- -c "shell_environment_policy.set.HERDR_PANE_ID=\"$(toml "$HERDR_PANE_ID")\"" "$@"
          if [ -n "${HERDR_ENV:-}" ]; then
            set -- -c "shell_environment_policy.set.HERDR_ENV=\"$(toml "$HERDR_ENV")\"" "$@"
          fi
        fi
        exec "$real" "$@"

        """#
}
