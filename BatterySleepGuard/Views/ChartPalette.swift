import SwiftUI

/// One colour per series, shared by the chart lines, the legends, the hover labels and the
/// readout, so a value is always shown in the colour of the line it belongs to.
enum ChartPalette {
    static let level = Color.indigo
    static let charge = Color.green
    static let discharge = Color.orange
    static let system = Color.blue
    static let adapter = Color.purple
    static let temperature = Color.red
    static let eta = Color.teal

    /// Battery flow colour: orange while the battery supplies power, green while it charges.
    static func flow(_ watts: Double) -> Color {
        watts < 0 ? discharge : charge
    }
}
