import Foundation

/// 主機檔案的 POSIX sh 腳本與輸出解析。
///
/// 規則(行為規格 §3.2、§8.4、R-U04):
/// - 指令是 `/bin/sh -c '<腳本>' purrdr '<參數>'…`:不依賴使用者的登入 shell(可能是 fish)。
///   腳本與參數都不含反斜線，因為 fish 在單引號內仍把 `\` 當特殊字元。
/// - 寫入的內容以 base64 放在參數裡;整個指令不超過 126 KiB。
/// - 跟隨 symlink 寫到真正的檔案(手動 `readlink` 迴圈最多 40 層，舊 macOS 沒有 `readlink -f`)。
/// - 每個退出路徑都清掉暫存檔;判斷結果靠 exit code,不比對 stderr 文字。
///
/// Windows 主機的 PowerShell 版本還沒做(ADR-0002)。
enum HostFileScript {
    static let maximumCommandLength = 126 * 1024
    /// 單一檔案的讀取上限。
    static let maximumFileSize = 1024 * 1024

    static func command(_ script: String, arguments: [String]) -> String {
        (["/bin/sh", "-c", PosixShell.quote(script), "purrdr"] + arguments.map(PosixShell.quote)).joined(separator: " ")
    }

    /// 共用開頭：固定 PATH 與 locale、新檔只有本人可讀、`resolve` 跟隨 symlink。
    static let prelude = """
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
        LC_ALL=C
        export PATH LC_ALL
        umask 077
        nl='
        '
        resolve() {
          p=$1
          n=0
          while [ -L "$p" ] && [ "$n" -lt 40 ]; do
            t=$(readlink "$p")
            case $t in
              /*) p=$t ;;
              *) p=$(dirname "$p")/$t ;;
            esac
            n=$((n + 1))
          done
          printf '%s' "$p"
        }
        checksum() {
          set -f
          set -- $(cksum < "$1")
          printf '%s:%s' "$1" "$2"
        }

        """

    /// 讀取：參數是相對於家目錄的路徑。輸出
    /// `purrdr-files 1` / `user <名稱>` / 每個檔案一筆：`missing <i>`、`nodir <i>`、`other <i>`、
    /// `unreadable <i>`、`toolarge <i>`,或 `file <i> <版本> <bytes>` 接著原始內容再一個換行。
    static let read = prelude + """
        tmp=$(mktemp "${TMPDIR:-/tmp}/purrdr.XXXXXX") || exit 70
        trap 'rm -f "$tmp"' EXIT
        printf 'purrdr-files 1%suser %s%s' "$nl" "$(id -un)" "$nl"
        i=0
        for rel in "$@"; do
          p=$(resolve "$HOME/$rel")
          if [ -f "$p" ]; then
            if [ ! -r "$p" ]; then
              printf 'unreadable %s%s' "$i" "$nl"
            elif [ "$(($(wc -c < "$p")))" -gt \(maximumFileSize) ]; then
              printf 'toolarge %s%s' "$i" "$nl"
            elif cat "$p" > "$tmp"; then
              size=$(($(wc -c < "$tmp")))
              printf 'file %s %s %s%s' "$i" "$(checksum "$tmp")" "$size" "$nl"
              cat "$tmp"
              printf '%s' "$nl"
            else
              printf 'unreadable %s%s' "$i" "$nl"
            fi
          elif [ -e "$p" ]; then
            printf 'other %s%s' "$i" "$nl"
          elif [ -d "$(dirname "$p")" ]; then
            printf 'missing %s%s' "$i" "$nl"
          else
            printf 'nodir %s%s' "$i" "$nl"
          fi
          i=$((i + 1))
        done
        """

    /// 套用變更：參數每五個一組(`put`／`del`／`rmtree`、路徑、`any`／`missing`／版本、base64、是否可執行)。
    /// 先檢查全部(不符 → 印 `changed <路徑>` exit 3;資料夾不存在 → `nodir <路徑>` exit 4),
    /// 全部符合才依序寫。覆寫既有檔案時先 `cp -p` 到暫存檔保留權限，再寫入內容、`mv` 換上。
    static let apply = prelude + """
        tmp=
        trap 'if [ -n "$tmp" ]; then rm -f "$tmp"; fi' EXIT
        check() {
          while [ "$#" -ge 5 ]; do
            kind=$1
            rel=$2
            expect=$3
            shift 5
            if [ "$kind" = rmtree ]; then continue; fi
            p=$(resolve "$HOME/$rel")
            case $expect in
              any) ;;
              missing)
                if [ -e "$p" ] || [ -L "$p" ]; then printf 'changed %s%s' "$rel" "$nl"; exit 3; fi ;;
              *)
                if [ ! -f "$p" ] || [ "$(checksum "$p")" != "$expect" ]; then printf 'changed %s%s' "$rel" "$nl"; exit 3; fi ;;
            esac
            if [ "$kind" = put ]; then
              case $rel in
                .purrdr/*) ;;
                *) if [ ! -d "$(dirname "$p")" ]; then printf 'nodir %s%s' "$rel" "$nl"; exit 4; fi ;;
              esac
            fi
          done
        }
        change() {
          while [ "$#" -ge 5 ]; do
            kind=$1
            rel=$2
            data=$4
            exe=$5
            shift 5
            p=$(resolve "$HOME/$rel")
            case $kind in
              put)
                d=$(dirname "$p")
                mkdir -p "$d" || exit 71
                tmp=$(mktemp "$d/.purrdr-tmp.XXXXXX") || exit 71
                if [ -f "$p" ]; then cp -p "$p" "$tmp" || exit 71; fi
                if ! printf '%s' "$data" | base64 --decode > "$tmp" 2> /dev/null; then
                  printf '%s' "$data" | base64 -d > "$tmp" || exit 72
                fi
                if [ "$exe" = 1 ]; then chmod 700 "$tmp" || exit 71; fi
                mv -f "$tmp" "$p" || exit 71
                tmp= ;;
              del)
                rm -f "$p" || exit 71 ;;
              rmtree)
                case $rel in
                  .purrdr/?*) rm -rf "$HOME/$rel" || exit 71 ;;
                  *) exit 64 ;;
                esac
                rmdir "$HOME/.purrdr" 2> /dev/null || : ;;
            esac
          done
        }
        check "$@"
        change "$@"
        """

    static func parseRead(_ output: Data, paths: [HostPath]) throws -> HostFileRead {
        var reader = LineReader(data: output)
        guard reader.line() == "purrdr-files 1", let userLine = reader.line(), userLine.hasPrefix("user ") else {
            throw HostFilesError.malformedOutput
        }
        var files: [HostPath: HostFileState] = [:]
        while let line = reader.line() {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 2, let index = Int(fields[1]), paths.indices.contains(index) else { throw HostFilesError.malformedOutput }
            switch fields[0] {
            case "missing": files[paths[index]] = .missing
            case "nodir": files[paths[index]] = .missingDirectory
            case "other": files[paths[index]] = .notRegularFile
            case "unreadable": files[paths[index]] = .unreadable
            case "toolarge": files[paths[index]] = .tooLarge
            case "file":
                guard fields.count == 4, let size = Int(fields[3]), let contents = reader.bytes(size), reader.line() == "" else {
                    throw HostFilesError.malformedOutput
                }
                files[paths[index]] = .file(contents, version: HostFileVersion(checksum: fields[2]))
            default:
                throw HostFilesError.malformedOutput
            }
        }
        guard files.count == paths.count else { throw HostFilesError.malformedOutput }
        return HostFileRead(user: String(userLine.dropFirst("user ".count)), files: files)
    }
}

/// 依 byte 位置讀行與固定長度內容(檔案內容可能含任何 bytes)。
private struct LineReader {
    let data: Data
    var offset: Data.Index

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func line() -> String? {
        guard offset < data.endIndex else { return nil }
        let end = data[offset...].firstIndex(of: 0x0A) ?? data.endIndex
        let text = String(decoding: data[offset..<end], as: UTF8.self)
        offset = min(end + 1, data.endIndex)
        return text
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard data.distance(from: offset, to: data.endIndex) >= count else { return nil }
        let end = data.index(offset, offsetBy: count)
        defer { offset = end }
        return Data(data[offset..<end])
    }
}
