import Foundation
import Testing

/// App 圖示(AppIcon.icon)的光學置中與翡翠綠色值(#280,ADR-0011;定義見 DESIGN.md)。
@Suite("App 圖示")
struct AppIconGeometryTests {
    static let opticalCenter = (x: 526.0, y: 505.0)
    static let tolerance = 4.0

    struct Bounds {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var center: (x: Double, y: Double) { ((minX + maxX) / 2, (minY + maxY) / 2) }

        mutating func include(x: Double, y: Double) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }

        mutating func include(_ other: Bounds) {
            include(x: other.minX, y: other.minY); include(x: other.maxX, y: other.maxY)
        }
    }

    static let iconFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/App/Purrdr/AppIcon.icon")

    static func svg(_ name: String) throws -> String {
        try String(contentsOf: iconFolder.appending(path: "Assets/\(name)"), encoding: .utf8)
    }

    static func attribute(_ name: String, in element: Substring) throws -> Double {
        let match = try #require(element.firstMatch(of: try Regex<(Substring, Substring)>(" \(name)=\"(-?[0-9.]+)\"")))
        return try #require(Double(match.1))
    }

    static func elements(_ tag: String, in svg: String) throws -> [Substring] {
        svg.matches(of: try Regex<Substring>("<\(tag) [^>]*>")).map(\.output)
    }

    static func circleBounds(in svg: String) throws -> Bounds {
        var bounds = Bounds()
        for circle in try elements("circle", in: svg) {
            let centerX = try attribute("cx", in: circle), centerY = try attribute("cy", in: circle)
            let radius = try attribute("r", in: circle)
            bounds.include(x: centerX - radius, y: centerY - radius)
            bounds.include(x: centerX + radius, y: centerY + radius)
        }
        return bounds
    }

    static func rectBounds(in svg: String) throws -> Bounds {
        var bounds = Bounds()
        for rect in try elements("rect", in: svg) {
            let originX = try attribute("x", in: rect), originY = try attribute("y", in: rect)
            bounds.include(x: originX, y: originY)
            bounds.include(x: originX + (try attribute("width", in: rect)), y: originY + (try attribute("height", in: rect)))
        }
        return bounds
    }

    /// 路徑的控制點界限(尾巴只用絕對座標的 M／Q 指令)。
    static func pathBounds(in svg: String) throws -> Bounds {
        var bounds = Bounds()
        for path in try elements("path", in: svg) {
            let data = try #require(path.firstMatch(of: /d="([^"]*)"/)).1
            let numbers = data.matches(of: /-?[0-9.]+/).compactMap { Double($0.output) }
            for index in stride(from: 0, to: numbers.count - 1, by: 2) {
                bounds.include(x: numbers[index], y: numbers[index + 1])
            }
        }
        return bounds
    }

    @Test("貓掌與打字點的整體外框中心在光學中心 (526, 505) ±4")
    func pawIsOpticallyCentered() throws {
        let paw = try Self.svg("1-paw.svg")
        var bounds = try Self.circleBounds(in: paw)
        bounds.include(try Self.rectBounds(in: paw))
        bounds.include(try Self.pathBounds(in: paw))
        bounds.include(try Self.circleBounds(in: try Self.svg("2-typing.svg")))
        #expect(abs(bounds.center.x - Self.opticalCenter.x) <= Self.tolerance, "外框中心 x = \(bounds.center.x)")
        #expect(abs(bounds.center.y - Self.opticalCenter.y) <= Self.tolerance, "外框中心 y = \(bounds.center.y)")
    }

    @Test("打字點中心等於泡泡本體中心")
    func typingDotsSitInBubbleCenter() throws {
        let bubble = try Self.rectBounds(in: try Self.svg("1-paw.svg")).center
        let dots = try Self.circleBounds(in: try Self.svg("2-typing.svg")).center
        #expect(bubble.x == dots.x && bubble.y == dots.y, "泡泡 \(bubble)、打字點 \(dots)")
    }

    @Test("貓掌淺色填色是翡翠綠 #0B7A5C")
    func pawLightFillIsEmerald() throws {
        let fill = try #require(try Self.svg("1-paw.svg").firstMatch(of: /<g fill="(#[0-9A-Fa-f]{6})"/)).1
        #expect(fill.uppercased() == "#0B7A5C")
    }

    @Test("貓掌深色 fill-specialization 是翡翠綠 #3CCF9E")
    func pawDarkFillIsEmerald() throws {
        let data = try Data(contentsOf: Self.iconFolder.appending(path: "icon.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let layers = (root["groups"] as? [[String: Any]] ?? []).flatMap { $0["layers"] as? [[String: Any]] ?? [] }
        let paw = try #require(layers.first { $0["image-name"] as? String == "1-paw.svg" })
        let specializations = paw["fill-specializations"] as? [[String: Any]] ?? []
        let dark = try #require(specializations.first { $0["appearance"] as? String == "dark" })
        let solid = try #require((dark["value"] as? [String: Any])?["solid"] as? String)
        let channels = solid.dropFirst("srgb:".count).split(separator: ",").compactMap { Double($0) }
        let hex = channels.prefix(3).map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        #expect(hex == "3CCF9E", "dark = \(solid)")
    }
}
