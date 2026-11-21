import Foundation
import PurrdrCore

/// 「傳送測試通知」的 SSH 實作(#328):在主機上用這支裝置的配對檔，對 Purrdr 後台送一則測試推播。
public struct SSHPushTestNotifier: Sendable {
    let channel: any HostChannel
    let deviceID: PushDeviceID
    /// 主機清單上這台的名稱(通知標題用)。
    let hostName: String
    let sleep: Sleep

    public init(channel: any HostChannel, deviceID: PushDeviceID, hostName: String, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.deviceID = deviceID
        self.hostName = hostName
        self.sleep = sleep
    }

    /// 主機上的腳本(經 `HostFileScript.command`,有自我時限):讀這支裝置的配對檔,對配對檔記的後台 endpoint
    /// POST `{"key":…,"event":"test","host_name":…}`(與主機服務的 `push.test` 同一個 payload);密鑰經 stdin 交給 curl,不出現在指令參數。
    /// 第二個參數是主機名稱已跳脫成 ASCII 的 JSON 字串內容(`jsonStringContent`),空的不帶 `host_name`。
    /// 輸出一行 HTTP 狀態碼;exit 66 沒有(完整的)配對、69 沒有 curl、70 連不上。
    /// Windows 版是 `WindowsScripts.pushTest`(`WindowsHostChannel.hostFileScripts` 登記)。
    static let script = #"""
        file="$HOME/.purrdr/$1/pairing"
        [ -f "$file" ] || exit 66
        key=$(sed -n 's/^key=//p' "$file" | head -n 1)
        endpoint=$(sed -n 's/^endpoint=//p' "$file" | head -n 1)
        case $key in
          '' | *[!0-9a-f]*) exit 66 ;;
        esac
        [ -n "$endpoint" ] || exit 66
        name=
        [ -z "$2" ] || name=",\"host_name\":\"$2\""
        command -v curl >/dev/null 2>&1 || exit 69
        code=$(printf '{"key":"%s","event":"test"%s}' "$key" "$name" |
          curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'content-type: application/json' \
            --data-binary @- "$endpoint") || exit 70
        printf '%s\n' "$code"
        """#

    public func send() async throws {
        let command = HostFileScript.command(Self.script, arguments: ["push-\(deviceID.rawValue)", Self.jsonStringContent(hostName)])
        let result = try await channel.collect(command, deadline: HostCommandDeadline.standard, sleep: sleep)
        let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.exitCode {
        case 0:
            let output = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let status = Int(output) else { throw PushTestNotificationError.failed(output) }
            if (200..<300).contains(status) { return }
            throw PushTestNotificationError(statusCode: status)
        case 66: throw PushTestNotificationError.notPaired
        case 69: throw PushTestNotificationError.curlMissing
        case 70: throw PushTestNotificationError.backendUnreachable(stderr)
        case 124: throw HostCommandError.deadlineExceeded
        default: throw PushTestNotificationError.failed(stderr)
        }
    }

    /// 後台限制的名稱長度(與 workspace 相同)。
    static let maximumNameLength = 100

    /// 主機名稱 → JSON 字串的內容(不含外層引號):最多 100 個字元，引號、反斜線、控制字元與所有非 ASCII 都以 `\uXXXX` 跳脫，
    /// 所以指令與 PowerShell 腳本都只有 ASCII、也不必處理引號。
    static func jsonStringContent(_ name: String) -> String {
        var result = ""
        for character in name.prefix(maximumNameLength) {
            for unit in String(character).utf16 {
                switch unit {
                case 0x20...0x7E where unit != 0x22 && unit != 0x5C:
                    result.unicodeScalars.append(Unicode.Scalar(unit)!)
                default:
                    result += String(format: "\\u%04x", unit)
                }
            }
        }
        return result
    }
}
