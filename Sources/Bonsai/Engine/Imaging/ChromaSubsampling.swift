import Foundation

/// Resolution of the color channels of a JPEG relative to its brightness.
enum ChromaSubsampling: Sendable {
    /// 4:4:4
    case full
    /// 4:2:2
    case half
    /// 4:2:0
    case quarter

    /// The value of cjpeg's `-sample` option.
    var samplingFactors: String {
        switch self {
        case .full: "1x1"
        case .half: "2x1"
        case .quarter: "2x2"
        }
    }
}
