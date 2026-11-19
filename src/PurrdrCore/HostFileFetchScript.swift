import Foundation

/// 主機取檔的 POSIX 長駐腳本與協定(#225,比照 `HostFileScript.follow`):一條 exec 通道服務查狀態與分塊讀取，
/// 閒置 `idleSeconds` 或總長 `totalSeconds` 到了以 exit 124 結束。
///
/// 請求一行(路徑以 base64 送，所以可含空白與任何 UTF-8;只因對話紀錄提到而放行時，工作目錄是 `noWorkingDirectory`):
/// - `stat <路徑> <工作目錄>` → `file <版本> <bytes>`／`missing`／`other`／`unreadable`／`denied`／`toolarge <bytes>`
/// - `read <路徑> <工作目錄> <版本> <offset> <length>` → 同上的非 `file` 狀態、`changed`,或
///   `chunk <offset> <bytes> <base64 長度>` 接著一行 base64
///
/// 每則回應最後一行 `end`。主機端的存取規則(與 app、主機服務共用案例 `vendor/purrdr-host/protocol/host-file-access.json`):
/// 工作目錄不能是 `/`、`$HOME` 或它的上層;沒有工作目錄時只放行暫存目錄、`~/.purrdr/uploads` 與 Claude 的 `tool-results`
/// (「是否出現在對話紀錄」由 app 判斷，見 ADR-0010);排除清單不分大小寫。先比對請求的路徑，再比對 `cd -P` 與 symlink 迴圈
/// 解析後的實際路徑;開檔後以開著的檔案(`/dev/fd/3`)的 inode 核對實際路徑。查狀態與從頭讀都把檔案複製成快照，
/// 之後的分塊從快照讀，分塊之間檔案被覆寫也不會拼出兩個版本。
/// Windows 主機(#226)由 `WindowsHostChannel` 換成同協定的 PowerShell 版本，以 `followInvocation` 認出。
package enum HostFileFetchScript {
    /// 一次讀取最多的 bytes(app 端以 `HostFileFetchLimits.chunkSize` 讀)。
    package static let maximumChunk = HostServiceProtocol.maximumFileChunk

    /// 請求裡「沒有工作目錄」(只因對話紀錄提到而放行)。
    package static let noWorkingDirectory = "-"

    package static func follow(
        maximumSize: Int = HostFileFetchLimits.maximumSize, idleSeconds: Int = HostScriptTimeLimit.followIdleSeconds,
        totalSeconds: Int = HostScriptTimeLimit.followTotalSeconds
    ) -> String {
        ([followInvocation] + [idleSeconds, totalSeconds, maximumSize].map { PosixShell.quote(String($0)) }).joined(separator: " ")
    }

    /// `follow` 參數之前的部分(Windows 方言與流量守門以它認出這支腳本)。
    package static let followInvocation = (["/bin/sh", "-c", PosixShell.quote(HostScriptTimeLimit.posix(script, seconds: "$2")), "purrdr"])
        .joined(separator: " ")

    /// 排除清單的 `case` 樣式(路徑已轉小寫):任何位置出現該段落，或以它結尾。段落加引號(可含空白),`*` 結尾留在引號外。
    static var excludedPatterns: String {
        HostFileAccessPolicy.excludedLocations.map { location in
            let lowered = location.lowercased()
            let quoted = lowered.hasSuffix("*") ? PosixShell.quote(String(lowered.dropLast())) + "*" : PosixShell.quote(lowered)
            return "*/\(quoted)|*/\(quoted)/*"
        }.joined(separator: "|")
    }

    /// 工作目錄以外可放行的系統暫存目錄(schema 的 `x-temporary-file-locations`),加引號。
    static var temporaryLocations: String {
        HostServiceProtocol.temporaryFileLocations.map(PosixShell.quote).joined(separator: " ")
    }

    static let script = HostFileScript.prelude + """
        trap 'exit 124' HUP
        idle=$1
        maximum=$3
        snapshot=$(mktemp "${TMPDIR:-/tmp}/purrdr-fetch.XXXXXX") || exit 70
        trap 'rm -f "$snapshot"' EXIT
        snapshot_version=
        snapshot_path=
        no_root=\(noWorkingDirectory)
        home_resolved=$(cd -P -- "$HOME" 2> /dev/null && pwd -P) || home_resolved=$HOME
        decode() {
          decoded=$(printf '%s' "$1" | base64 --decode 2> /dev/null) || decoded=$(printf '%s' "$1" | base64 -d 2> /dev/null) || decoded=$(printf '%s' "$1" | base64 -D)
          printf '%s' "$decoded"
        }
        resolved_path() {
          link_target=$(resolve "$1")
          resolved_folder=$(cd -P -- "$(dirname -- "$link_target")" 2> /dev/null && pwd -P) || return 1
          resolved_name=$(basename -- "$link_target")
          if [ "$resolved_folder" = / ]; then printf '/%s' "$resolved_name"; else printf '%s/%s' "$resolved_folder" "$resolved_name"; fi
        }
        excluded() {
          lowered=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
          case $lowered in
            \(excludedPatterns)) return 0 ;;
          esac
          return 1
        }
        under() {
          [ -n "$2" ] || return 1
          case $1 in "${2%/}"/*) return 0 ;; esac
          return 1
        }
        too_broad() {
          [ "$1" = / ] && return 0
          for home_form in "$HOME" "$home_resolved"; do
            case "$home_form/" in "${1%/}"/*) return 0 ;; esac
          done
          return 1
        }
        mentionable() {
          for location in \(temporaryLocations) "${TMPDIR:-}" "$HOME/.purrdr/uploads" "$home_resolved/.purrdr/uploads"; do
            under "$1" "$location" && return 0
          done
          for claude_folder in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$home_resolved/.claude"; do
            case $1 in "$claude_folder"/projects/*/*/tool-results/*) return 0 ;; esac
          done
          return 1
        }
        allowed() {
          case $1 in /*) ;; *) return 1 ;; esac
          case "$1/" in */./*|*/../*) return 1 ;; esac
          excluded "$1" && return 1
          if [ "$2" = "$no_root" ]; then mentionable "$1"; return; fi
          too_broad "$2" && return 1
          under "$1" "$2"
        }
        inode_of() {
          set -- $(ls -di "$1" 2> /dev/null)
          printf '%s' "${1:-none}"
        }
        open_inode() {
          set -- $(ls -diL /dev/fd/3 2> /dev/null)
          printf '%s' "${1:-unknown}"
        }
        locate() {
          verdict=denied
          target=
          allowed "$1" "$2" || return
          verdict=missing
          if [ "$2" = "$no_root" ]; then resolved_root=$no_root; else resolved_root=$(cd -P -- "$2" 2> /dev/null && pwd -P) || return; fi
          target=$(resolved_path "$1") || return
          verdict=denied
          allowed "$target" "$resolved_root" || return
          if [ -f "$target" ]; then
            # 讀不到大小(剛被刪掉)時當成缺檔;空值進算術會讓 shell 結束。
            size=$(wc -c < "$target" 2> /dev/null | tr -d ' ')
            case $size in ''|*[!0-9]*) verdict=missing; return ;; esac
            if [ "$size" -gt "$maximum" ]; then verdict="toolarge $size"; return; fi
            verdict=file
          elif [ -e "$target" ]; then
            verdict=other
          else
            verdict=missing
          fi
        }
        take_snapshot() {
          # 先 cd 進檢查過的資料夾再以相對路徑開檔：之後資料夾被換成 symlink 也不影響(工作目錄跟著原本的資料夾)。
          # 開著的檔案(fd 3)必須是一般檔案，且與資料夾裡這個名稱(不跟隨 symlink)是同一個 inode。
          # 重導向放在 { } 上：開檔失敗只讓這個指令失敗，不結束 shell。3 是被拒，其他非 0 是讀不到。
          (
            target_folder=$(dirname -- "$target")
            target_name=$(basename -- "$target")
            cd -P -- "$target_folder" 2> /dev/null && [ "$(pwd -P)" = "$target_folder" ] || exit 3
            {
              [ -f /dev/fd/3 ] && [ ! -L "./$target_name" ] && [ "$(open_inode)" = "$(inode_of "./$target_name")" ] || exit 3
              head -c "$((maximum + 1))" <&3 > "$snapshot"
            } 3< "./$target_name" 2> /dev/null
          )
          case $? in
            0) ;;
            3) verdict=denied; return 1 ;;
            *) verdict=unreadable; return 1 ;;
          esac
          snapshot_size=$(($(wc -c < "$snapshot")))
          if [ "$snapshot_size" -gt "$maximum" ]; then verdict="toolarge $snapshot_size"; snapshot_path=; return 1; fi
          snapshot_version=$(checksum "$snapshot")
          snapshot_path=$target
        }
        stat_request() {
          locate "$1" "$2"
          if [ "$verdict" = file ] && take_snapshot; then
            printf 'file %s %s%s' "$snapshot_version" "$snapshot_size" "$nl"
          else
            printf '%s%s' "$verdict" "$nl"
          fi
        }
        read_request() {
          locate "$1" "$2"
          if [ "$verdict" != file ]; then printf '%s%s' "$verdict" "$nl"; return; fi
          case $4$5 in *[!0-9]*|'') printf 'bad%s' "$nl"; return ;; esac
          if [ "$4" = 0 ] || [ "$snapshot_path" != "$target" ] || [ "$snapshot_version" != "$3" ]; then
            if ! take_snapshot; then printf '%s%s' "$verdict" "$nl"; return; fi
          fi
          if [ "$snapshot_version" != "$3" ]; then printf 'changed%s' "$nl"; return; fi
          total=$snapshot_size
          count=$5
          if [ "$count" -gt \(maximumChunk) ]; then count=\(maximumChunk); fi
          if [ "$4" -ge "$total" ]; then count=0; elif [ $(($4 + count)) -gt "$total" ]; then count=$((total - $4)); fi
          printf 'chunk %s %s %s%s' "$4" "$count" "$((4 * ((count + 2) / 3)))" "$nl"
          if [ "$count" -gt 0 ]; then tail -c +$(($4 + 1)) "$snapshot" | head -c "$count" | base64 | tr -d "$nl"; fi
          printf '%s' "$nl"
        }
        purrdr_limit "$$" "$idle" < /dev/null > /dev/null 2>&1 &
        idle_limit=$!
        set -f
        while IFS= read -r request; do
          kill "$idle_limit" 2> /dev/null
          purrdr_limit "$$" "$idle" < /dev/null > /dev/null 2>&1 &
          idle_limit=$!
          set -- $request
          case $1 in
            stat|read)
              operation=$1
              if [ "$operation" = stat ] && [ "$#" -ne 3 ] || [ "$operation" = read ] && [ "$#" -ne 6 ]; then
                printf 'bad%s' "$nl"
              else
                requested_path=$(decode "$2")
                if [ "$3" = "$no_root" ]; then requested_root=$no_root; else requested_root=$(decode "$3"); fi
                if [ "$operation" = stat ]; then stat_request "$requested_path" "$requested_root"; else read_request "$requested_path" "$requested_root" "$4" "$5" "$6"; fi
              fi ;;
            *) printf 'bad%s' "$nl" ;;
          esac
          printf 'end%s' "$nl"
        done
        """

    // MARK: - 請求與回應

    package static func statusRequest(_ target: HostFileTarget) -> Data {
        Data((["stat"] + encoded(target)).joined(separator: " ").appending("\n").utf8)
    }

    package static func readRequest(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) -> Data {
        Data((["read"] + encoded(target) + [version.checksum, String(offset), String(length)]).joined(separator: " ").appending("\n").utf8)
    }

    private static func encoded(_ target: HostFileTarget) -> [String] {
        [Data(target.path.utf8).base64EncodedString(), target.root.map { Data($0.utf8).base64EncodedString() } ?? noWorkingDirectory]
    }

    /// 一則回應(`end` 之前的行;`chunk` 的內容已解 base64)。
    package enum Reply: Sendable, Equatable {
        case status(HostFileStatus)
        case chunk(offset: Int, data: Data)
        case changed
    }

    /// 從緩衝取出一則完整的回應;還不完整回傳 `nil`,格式不對丟 `HostFileFetchError.failed`。
    package static func takeReply(from buffer: inout Data) throws -> Reply? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
        var next = buffer.index(after: newline)
        let fields = line.split(separator: " ").map(String.init)
        let reply: Reply
        switch fields.first {
        case "file":
            guard fields.count == 3, let size = Int(fields[2]) else { throw malformed(line) }
            reply = .status(.file(version: HostFileVersion(checksum: fields[1]), size: size))
        case "toolarge":
            guard fields.count == 2, let size = Int(fields[1]) else { throw malformed(line) }
            reply = .status(.tooLarge(size: size))
        case "missing": reply = .status(.missing)
        case "other": reply = .status(.notRegularFile)
        case "unreadable": reply = .status(.unreadable)
        case "denied": reply = .status(.denied)
        case "changed": reply = .changed
        case "chunk":
            guard fields.count == 4, let offset = Int(fields[1]), let count = Int(fields[2]), let encodedLength = Int(fields[3]) else {
                throw malformed(line)
            }
            guard buffer.distance(from: next, to: buffer.endIndex) >= encodedLength + 1 else { return nil }
            let end = buffer.index(next, offsetBy: encodedLength)
            guard let data = Data(base64Encoded: buffer[next..<end]), data.count == count else { throw malformed("chunk \(offset)") }
            reply = .chunk(offset: offset, data: data)
            next = buffer.index(after: end)
        default:
            throw malformed(line)
        }
        // 回應最後一行是 `end`。
        guard let endLine = buffer[next...].firstIndex(of: 0x0A) else { return nil }
        guard String(decoding: buffer[next..<endLine], as: UTF8.self) == "end" else { throw malformed("missing end") }
        buffer.removeSubrange(..<buffer.index(after: endLine))
        return reply
    }

    private static func malformed(_ detail: String) -> HostFileFetchError {
        .failed("malformed host file reply: \(detail.prefix(80))")
    }
}
