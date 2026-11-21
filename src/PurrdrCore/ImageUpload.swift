import Foundation

/// 上傳到主機的圖片檔名(行為規格 F7):只允許 `[A-Za-z0-9-]+\.(jpg|png)`。
///
/// 檔名會原樣交給主機腳本、也會出現在 prompt 裡，所以在 app 端就擋掉其他字元。
public struct UploadFileName: Hashable, Sendable {
    public let value: String

    public init?(_ value: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, ["jpg", "png"].contains(parts[1]), !parts[0].isEmpty, parts[0].allSatisfy(allowed.contains) else {
            return nil
        }
        self.value = value
    }

    /// `<時間(毫秒)base36>-<8 個 base36 亂數>.jpg`。
    public static func make(date: Date, random: inout some RandomNumberGenerator) -> UploadFileName {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let millis = Int64(max(0, date.timeIntervalSince1970 * 1000))
        let suffix = String((0..<8).map { _ in digits[Int.random(in: 0..<36, using: &random)] })
        return UploadFileName("\(String(millis, radix: 36))-\(suffix).jpg")!
    }
}

/// 上傳到主機的指令(POSIX;Windows 主機由 `WindowsHostChannel` 換成 `WindowsScripts.hostUpload`)。圖片與一般檔案共用。
///
/// - 指令只帶檔名與大小,bytes 走 exec 的 stdin(ADR-0003:沒有 SFTP;也避開 sshd 單一參數 128 KiB 的上限)。
///   app 送完 bytes 後送 EOF。
/// - 寫到系統暫存目錄(`TMPDIR`,沒設定用 `/tmp`)底下的 `purrdr-uploads-<uid>/`(與主機服務共用,名稱來自 schema 的 `x-upload-folder`)
///   的隱藏暫存檔;資料夾已存在時必須是自己的真資料夾(不是 symlink、擁有者是自己、權限剛好 700),否則 exit 71、不寫入。收到的大小與宣告的不同(上傳中斷)就刪掉暫存檔、失敗結束;
///   相同才 `mv` 成正式檔。同名檔案已存在則拒絕，永不覆寫(§8.4)。
/// - `umask 077`,上傳資料夾 700:只有本人可讀。
/// - 成功後刪掉上傳資料夾與舊版 `~/.purrdr/uploads/` 裡 7 天(10,080 分鐘)前的檔案(含中斷留下的暫存檔),
///   舊資料夾空了就移除,印出絕對路徑。
/// - 腳本不含反斜線(fish 在單引號內仍處理 `\`)、不明確 `exit 0`(行為規格 §3.2)。
public enum HostUploadCommand {
    static let script = HostScriptTimeLimit.posixUpload("""
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
        LC_ALL=C
        export PATH LC_ALL
        umask 077
        name=$1
        size=$2
        case $name in
          '' | .* | *[!A-Za-z0-9.-]*) exit 64 ;;
        esac
        d=${TMPDIR:-/tmp}
        d=${d%/}/\(HostServiceProtocol.uploadFolder)-$(id -u) || exit 71
        if [ -L "$d" ]; then echo "upload folder is a symlink" >&2; exit 71; fi
        mkdir -m 700 "$d" 2> /dev/null
        if [ ! -d "$d" ] || [ -L "$d" ] || [ ! -O "$d" ]; then echo "upload folder is not owned by you" >&2; exit 71; fi
        case $(ls -ld "$d" | cut -c1-10) in
          drwx------) ;;
          *) echo "upload folder is accessible by others" >&2; exit 71 ;;
        esac
        tmp=$(mktemp "$d/.upload.XXXXXX") || exit 71
        trap 'rm -f "$tmp"' EXIT
        trap 'rm -f "$tmp"; exit 70' HUP INT TERM PIPE
        cat > "$tmp" || exit 72
        got=$(($(wc -c < "$tmp")))
        if [ "$got" != "$size" ]; then exit 75; fi
        if [ -e "$d/$name" ] || [ -L "$d/$name" ]; then exit 73; fi
        mv "$tmp" "$d/$name" || exit 71
        tmp=
        find "$d" -type f -mmin +10080 -exec rm -f {} + 2> /dev/null
        old=$HOME/.purrdr/uploads
        if [ -d "$old" ] && [ ! -L "$old" ]; then
          find "$old" -type f -mmin +10080 -exec rm -f {} + 2> /dev/null
          rmdir "$old" 2> /dev/null
        fi
        printf '%s/%s
        ' "$d" "$name"
        """, transferSizeParameter: 2)

    public static func posix(name: HostUploadName, size: Int) -> String {
        ["/bin/sh", "-c", PosixShell.quote(script), "purrdr-upload", PosixShell.quote(name.value), PosixShell.quote(String(size))].joined(separator: " ")
    }

    /// Demo 主機與 Windows 通道用：認得上傳指令就回傳檔名與大小。
    public static func parse(_ command: String) -> (name: HostUploadName, size: Int)? {
        let prefix = ["/bin/sh", "-c", PosixShell.quote(script), "purrdr-upload"].joined(separator: " ") + " "
        guard command.hasPrefix(prefix) else { return nil }
        let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))) ?? []
        guard arguments.count == 2, let name = HostUploadName(arguments[0]), let size = Int(arguments[1]) else { return nil }
        return (name, size)
    }
}

/// 圖片上傳的限制。
public enum ImageUploadLimit {
    /// 單張上限，以使用者挑的原始圖片判斷(`ConversationModel.addImages`)。
    public static let maximumSize = 20 * 1024 * 1024
}
