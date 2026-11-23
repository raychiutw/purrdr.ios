import Foundation

/// 鍵盤升降時終端機視圖要用的高度(#357)。
///
/// Pane 終端機的欄列數會變成 Pane 在電腦上的尺寸,所以鍵盤升降不能改欄列數:容器因鍵盤變矮時,
/// 終端機視圖維持原高度、只上移到游標可見(`offset`);旋轉與字級才重新算格數。純邏輯，不依賴 UIKit。
public struct TerminalKeyboardViewport: Equatable, Sendable {
    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// 鍵盤升起前的容器大小(沒有鍵盤時是目前的容器大小)。
    private var baseline: Size?
    /// 鍵盤擋住容器時，終端機維持的高度(升起前的容器高度);沒有就是沒釘住。
    private var pinnedHeight: Double?

    public init() {}

    /// 依目前容器大小與鍵盤狀態回傳終端機視圖該用的高度。
    ///
    /// - 沒有鍵盤:照容器高度。
    /// - 鍵盤升起且容器寬度不變、變矮了:維持升起前的高度(列數不變)。
    /// - 容器寬度變了(旋轉):旋轉本來就要重新算格數，以新的容器大小為準。
    /// - 實體鍵盤(容器沒變矮):照容器高度。
    public mutating func terminalHeight(container: Size, keyboardVisible: Bool) -> Double {
        guard keyboardVisible else {
            baseline = container
            pinnedHeight = nil
            return container.height
        }
        if let pinnedHeight {
            guard baseline?.width == container.width else {
                baseline = container
                self.pinnedHeight = nil
                return container.height
            }
            return max(pinnedHeight, container.height)
        }
        if let baseline, baseline.width == container.width, container.height < baseline.height {
            pinnedHeight = baseline.height
            return baseline.height
        }
        baseline = baseline?.width == container.width ? baseline : container
        return container.height
    }

    /// 終端機視圖相對容器上緣的位移(≤ 0):游標底緣被鍵盤擋住時往上移到剛好看到,最多移到終端機底。
    public static func offset(caretBottom: Double, visibleHeight: Double, terminalHeight: Double) -> Double {
        guard terminalHeight > visibleHeight, caretBottom > visibleHeight else { return 0 }
        return -min(caretBottom - visibleHeight, terminalHeight - visibleHeight)
    }
}
