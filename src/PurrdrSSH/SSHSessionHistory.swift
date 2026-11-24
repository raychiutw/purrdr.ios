import Foundation
import PurrdrCore

/// SSH 主機列出資料夾過去的 Claude Code／Codex session(#535):一次性 POSIX 腳本(Windows 換成 `WindowsScripts.sessionHistory`),
/// 輸出對齊主機服務的 `sessions.list`(purrdr.host 的 `session_history.rs`):id、最後修改時間、第一則使用者訊息的摘要,新到舊,最多 50 個。
///
/// 參數:`種類(claude|codex) 工作資料夾 Claude 專案資料夾名`。輸出每個 session 一行「id TAB 修改時間(epoch 秒) TAB 摘要」,
/// 資料夾或紀錄不存在就是空輸出、exit 0。只讀每個檔案開頭 1 MiB;摘要已合併空白並截在 480 bytes(client 再取前 120 字,避免腳本在 C locale 切斷 UTF-8)。
/// - Claude:`<設定目錄>/projects/<資料夾名>/*.jsonl`,id 是檔名;摘要略過 `isMeta`、`<…>` 開頭(指令與系統注入)、`[Request interrupted…`、工具結果。
/// - Codex:`<CODEX_HOME>/sessions/` 底下 `rollout-*.jsonl` 的 `session_meta` cwd 等於工作資料夾;摘要取 `user_message` 或使用者角色的 `input_text`。
/// 不解析完整 JSON(主機不一定有 python／jq):依 Claude Code 與 Codex 的緊湊序列化找固定的鍵,字串逸出由 awk 還原。
public enum SessionHistoryCommand {
    static let tag = "purrdr-sessions"
    /// 最多列出幾個 session(與主機服務相同)。
    static let maximumSessions = 50
    static let summaryCharacters = 120
    static let usageExitCode: Int32 = 64

    /// awk 程式不含連續的反斜線(fish 在單引號內把 `\\` 當成一個):反斜線、引號、tab 都以 `sprintf("%c", …)` 取得。
    static let awkProgram = #"""
        function after(s, key,    i) { i = index(s, key); return i ? i + length(key) : 0 }
        function jstr(s, p,    out, c, e, n) {
          out = ""
          n = length(s)
          while (p <= n && length(out) < 4000) {
            c = substr(s, p, 1)
            if (c == Q) break
            if (c == BS) {
              e = substr(s, p + 1, 1)
              p += 2
              if (e == "n" || e == "t" || e == "r") out = out " "
              else if (e == "u") { out = out "?"; p += 4 }
              else out = out e
            } else { out = out c; p++ }
          }
          return out
        }
        function typed(t) {
          gsub(/[ \t\r\n]+/, " ", t)
          sub(/^ /, "", t)
          sub(/ $/, "", t)
          if (t == "" || substr(t, 1, 1) == "<" || index(t, "[Request interrupted") == 1) return ""
          return t
        }
        function claude_text(line,    p, c, k) {
          if (!index(line, Q "type" Q ":" Q "user" Q) || index(line, Q "isMeta" Q ":true")) return ""
          p = after(line, Q "role" Q ":" Q "user" Q "," Q "content" Q ":")
          if (!p) return ""
          c = substr(line, p, 1)
          if (c == Q) return jstr(line, p + 1)
          k = "[{" Q "type" Q ":" Q "text" Q "," Q "text" Q ":" Q
          if (substr(line, p, length(k)) == k) return jstr(line, p + length(k))
          return ""
        }
        function codex_text(line,    p) {
          if (index(line, Q "type" Q ":" Q "user_message" Q)) {
            p = after(line, Q "message" Q ":" Q)
            return p ? jstr(line, p) : ""
          }
          if (index(line, Q "role" Q ":" Q "user" Q)) {
            p = after(line, Q "type" Q ":" Q "input_text" Q "," Q "text" Q ":" Q)
            return p ? jstr(line, p) : ""
          }
          return ""
        }
        BEGIN {
          Q = sprintf("%c", 34); BS = sprintf("%c", 92); T = sprintf("%c", 9)
          safe = "^[A-Za-z0-9][A-Za-z0-9-]*$"
          found = 0
        }
        {
          if (found >= max) exit
          i = index($0, " ")
          if (i < 2) next
          epoch = substr($0, 1, i - 1)
          path = substr($0, i + 1)
          id = ""; summary = ""; bytes = 0; ok = 0
          if (kind == "claude") {
            n = split(path, parts, "/")
            id = parts[n]
            id = substr(id, 1, length(id) - 6)
            if (id !~ safe) next
            ok = 1
          }
          while ((getline line < path) > 0) {
            bytes += length(line) + 1
            if (bytes > 1048576) break
            if (kind == "codex" && !ok) {
              if (index(line, Q "type" Q ":" Q "session_meta" Q)) {
                p = after(line, Q "payload" Q ":{" Q "id" Q ":" Q)
                if (!p) p = after(line, Q "id" Q ":" Q)
                id = p ? jstr(line, p) : ""
                p = after(line, Q "cwd" Q ":" Q)
                if (id !~ safe || !p || jstr(line, p) != cwd) break
                ok = 1
              }
              continue
            }
            t = typed(kind == "claude" ? claude_text(line) : codex_text(line))
            if (t != "") { summary = substr(t, 1, 480); break }
          }
          close(path)
          if (!ok) next
          print id T epoch T summary
          found++
        }
        """#

    static let script = HostScriptTimeLimit.posixRead("""
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
        LC_ALL=C
        export PATH LC_ALL
        case $1 in
        claude) d=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$3; name='*.jsonl'; depth=1 ;;
        codex) d=${CODEX_HOME:-$HOME/.codex}/sessions; name='rollout-*.jsonl'; depth=6 ;;
        *) exit \(usageExitCode) ;;
        esac
        if [ ! -d "$d" ]; then exit 0; fi
        if stat -c %Y / >/dev/null 2>&1; then
        find "$d" -maxdepth "$depth" -type f -name "$name" -exec stat -c '%Y %n' {} +
        else
        find "$d" -maxdepth "$depth" -type f -name "$name" -exec stat -f '%m %N' {} +
        fi | sort -k1,1nr -k2 | awk -v kind="$1" -v cwd="$2" -v max=\(maximumSessions) '\(awkProgram)'
        """)

    public static func command(kind: String, cwd: String) -> String {
        (["/bin/sh", "-c", PosixShell.quote(script), tag] + [kind, cwd, ClaudeTranscript.projectFolder(forCWD: cwd)].map(PosixShell.quote))
            .joined(separator: " ")
    }

    /// 指令的參數(`種類 資料夾 專案資料夾名`);不是這個指令回 `nil`(Windows 版換成 PowerShell 腳本用)。
    static func arguments(in command: String) -> [String]? {
        let prefix = ["/bin/sh", "-c", PosixShell.quote(script), tag].joined(separator: " ") + " "
        guard command.hasPrefix(prefix), let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))),
              arguments.count == 3 else { return nil }
        return arguments
    }

    /// 腳本輸出 → session 清單(沿用腳本的順序;看不懂的行略過)。
    static func parse(_ stdout: Data) -> [ResumableSession] {
        stdout.split(separator: 0x0A).compactMap { line in
            let fields = line.split(separator: 0x09, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2, let epoch = TimeInterval(String(decoding: fields[1], as: UTF8.self)) else { return nil }
            let id = String(decoding: fields[0], as: UTF8.self)
            guard !id.isEmpty else { return nil }
            let text = fields.count == 3 ? String(String(decoding: fields[2], as: UTF8.self).prefix(summaryCharacters)) : ""
            return ResumableSession(id: id, modified: Date(timeIntervalSince1970: epoch), summary: text.isEmpty ? nil : text)
        }
    }
}

/// SSH 主機的過去 session 清單(#535):經一次性指令的入口(`collect`,有期限)跑 `SessionHistoryCommand`。
public struct SSHSessionHistory: Sendable {
    let channel: any HostChannel
    let sleep: Sleep

    public init(channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.sleep = sleep
    }

    /// `cwd` 過去的 `kind`(`claude`／`codex`)session,新到舊。主機跑不了腳本(Demo 主機 exit 127、Windows 通道不認得)當作沒有。
    public func sessions(cwd: String, kind: String, deadline: Duration = HostCommandDeadline.standard) async throws -> [ResumableSession] {
        let result: CommandResult
        do {
            result = try await channel.collect(SessionHistoryCommand.command(kind: kind, cwd: cwd), deadline: deadline, sleep: sleep)
        } catch is WindowsCommandError {
            return []
        } catch HostCommandError.deadlineExceeded {
            throw HerdrError.deadlineExceeded
        }
        switch result.exitStatus {
        case .some(0): return SessionHistoryCommand.parse(result.stdout)
        case .some(127): return []
        default: throw HerdrError.noResponse(exitCode: result.exitStatus, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
    }
}
