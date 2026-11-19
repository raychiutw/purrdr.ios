import Foundation

/// 主機取檔的 POSIX 長駐腳本與協定(#225,比照 `HostFileScript.follow`):一條 exec 通道服務查狀態與分塊讀取，
/// 閒置 `idleSeconds` 或總長 `totalSeconds` 到了以 exit 124 結束。
///
/// 請求一行(路徑以 base64 送，所以可含空白與任何 UTF-8;工作目錄沒有時是 `-`):
/// - `stat <路徑> <工作目錄>` → `file <版本> <bytes>`／`missing`／`other`／`unreadable`／`denied`／`toolarge <bytes>`
/// - `read <路徑> <工作目錄> <版本> <offset> <length>` → 同上的非 `file` 狀態、`changed`,或
///   `chunk <offset> <bytes> <base64 長度>` 接著一行 base64
///
/// 每則回應最後一行 `end`。主機端的存取規則(權威):以 `cd -P` 與 symlink 迴圈解析成實際路徑後，
/// 在排除清單(`HostFileAccessPolicy.excludedLocations`,不分大小寫)就拒絕;有工作目錄時實際路徑必須在解析後的工作目錄之下。
/// 從頭讀(offset 0)時把檔案複製成快照並確認版本，之後的分塊都從快照讀，所以分塊之間檔案被覆寫也不會拼出兩個版本。
/// Windows 主機(#226)由 `WindowsHostChannel` 換成同協定的 PowerShell 版本，以 `followInvocation` 認出。
package enum HostFileFetchScript {
    /// 一次讀取最多的 bytes(app 端以 `HostFileFetchLimits.chunkSize` 讀)。
    package static let maximumChunk = 1024 * 1024

    package static func follow(
        maximumSize: Int = HostFileFetchLimits.maximumSize, idleSeconds: Int = HostScriptTimeLimit.followIdleSeconds,
        totalSeconds: Int = HostScriptTimeLimit.followTotalSeconds
    ) -> String {
        ([followInvocation] + [idleSeconds, totalSeconds, maximumSize].map { PosixShell.quote(String($0)) }).joined(separator: " ")
    }

    /// `follow` 參數之前的部分(Windows 方言與流量守門以它認出這支腳本)。
    package static let followInvocation = (["/bin/sh", "-c", PosixShell.quote(HostScriptTimeLimit.posix(script, seconds: "$2")), "purrdr"])
        .joined(separator: " ")

    /// 排除清單的 `case` 樣式(路徑已轉小寫):任何位置出現該段落，或以它結尾。
    static var excludedPatterns: String {
        HostFileAccessPolicy.excludedLocations.map { location in
            let lowered = location.lowercased()
            return "*/\(lowered)|*/\(lowered)/*"
        }.joined(separator: "|")
    }

    static let script = HostFileScript.prelude + """
        trap 'exit 124' HUP
        idle=$1
        maximum=$3
        snap=$(mktemp "${TMPDIR:-/tmp}/purrdr-fetch.XXXXXX") || exit 70
        trap 'rm -f "$snap"' EXIT
        snapversion=
        snappath=
        decode() {
          v=$(printf '%s' "$1" | base64 --decode 2> /dev/null) || v=$(printf '%s' "$1" | base64 -d 2> /dev/null) || v=$(printf '%s' "$1" | base64 -D)
          printf '%s' "$v"
        }
        canon() {
          c=$(resolve "$1")
          d=$(cd -P -- "$(dirname -- "$c")" 2> /dev/null && pwd -P) || return 1
          b=$(basename -- "$c")
          if [ "$d" = / ]; then printf '/%s' "$b"; else printf '%s/%s' "$d" "$b"; fi
        }
        excluded() {
          l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
          case $l in
            \(excludedPatterns)) return 0 ;;
          esac
          return 1
        }
        allowed() {
          case $1 in /*) ;; *) return 1 ;; esac
          excluded "$1" && return 1
          [ "$2" = - ] && return 0
          [ "$2" = / ] && return 0
          case $1 in "$2"/*) return 0 ;; esac
          return 1
        }
        locate() {
          verdict=denied
          target=
          if [ "$2" = - ]; then rootcanon=-; else rootcanon=$(cd -P -- "$2" 2> /dev/null && pwd -P) || return; fi
          allowed "$1" "$2" || return
          if ! target=$(canon "$1"); then verdict=missing; return; fi
          allowed "$target" "$rootcanon" || return
          if [ -f "$target" ]; then
            if [ ! -r "$target" ]; then verdict=unreadable; return; fi
            size=$(($(wc -c < "$target")))
            if [ "$size" -gt "$maximum" ]; then verdict="toolarge $size"; return; fi
            verdict=file
          elif [ -e "$target" ]; then
            verdict=other
          else
            verdict=missing
          fi
        }
        stat_request() {
          locate "$1" "$2"
          if [ "$verdict" = file ]; then
            printf 'file %s %s%s' "$(checksum "$target")" "$size" "$nl"
          else
            printf '%s%s' "$verdict" "$nl"
          fi
        }
        read_request() {
          locate "$1" "$2"
          if [ "$verdict" != file ]; then printf '%s%s' "$verdict" "$nl"; return; fi
          case $4$5 in *[!0-9]*|'') printf 'bad%s' "$nl"; return ;; esac
          if [ "$4" = 0 ] || [ "$snappath" != "$target" ] || [ "$snapversion" != "$3" ]; then
            if ! cat "$target" > "$snap"; then printf 'unreadable%s' "$nl"; return; fi
            snapversion=$(checksum "$snap")
            snappath=$target
          fi
          if [ "$snapversion" != "$3" ]; then printf 'changed%s' "$nl"; return; fi
          total=$(($(wc -c < "$snap")))
          count=$5
          if [ "$count" -gt \(maximumChunk) ]; then count=\(maximumChunk); fi
          if [ "$4" -ge "$total" ]; then count=0; elif [ $(($4 + count)) -gt "$total" ]; then count=$((total - $4)); fi
          printf 'chunk %s %s %s%s' "$4" "$count" "$((4 * ((count + 2) / 3)))" "$nl"
          if [ "$count" -gt 0 ]; then tail -c +$(($4 + 1)) "$snap" | head -c "$count" | base64 | tr -d "$nl"; fi
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
            stat)
              if [ "$#" -eq 3 ]; then
                p=$(decode "$2")
                if [ "$3" = - ]; then r=-; else r=$(decode "$3"); fi
                stat_request "$p" "$r"
              else
                printf 'bad%s' "$nl"
              fi ;;
            read)
              if [ "$#" -eq 6 ]; then
                p=$(decode "$2")
                if [ "$3" = - ]; then r=-; else r=$(decode "$3"); fi
                read_request "$p" "$r" "$4" "$5" "$6"
              else
                printf 'bad%s' "$nl"
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
        [Data(target.path.utf8).base64EncodedString(), target.root.map { Data($0.utf8).base64EncodedString() } ?? "-"]
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
