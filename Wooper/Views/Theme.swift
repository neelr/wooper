import SwiftUI

// Shared palette, lifted from the papery website (src/html.ts): warm off-white
// paper, near-black ink, grey meta, pink hearts, yellow highlight pills. Both
// tabs use this so the app reads as one product.
extension Color {
    static let paperyBg = Color(red: 0.992, green: 0.992, blue: 0.988)   // #fdfdfc
    static let paperyInk = Color(red: 0.09, green: 0.09, blue: 0.09)      // ~#111
    static let paperyMeta = Color(red: 0.6, green: 0.6, blue: 0.6)        // #999
    static let paperyHeart = Color(red: 0.878, green: 0.141, blue: 0.369) // #e0245e
    static let paperyHlText = Color(red: 0.541, green: 0.427, blue: 0.0)  // #8a6d00
    static let paperyHlBg = Color(red: 1.0, green: 0.831, blue: 0.0)      // #ffd400
}
