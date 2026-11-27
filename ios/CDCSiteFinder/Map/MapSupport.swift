import CoreLocation
import SwiftUI
import UIKit

/// Interface colours. Each one has a light and a dark version, so the app follows the
/// system appearance (the report's checklist asks for dark mode).
enum Theme {
    /// Brand gold. Same in both modes.
    static let yellow = Color(hex: 0xF7B500)
    /// Brand brown for text, icons and tints. Turns light tan in dark mode so it stays readable.
    static let brown = Color(light: 0x4A2511, dark: 0xF0C08A)
    /// Brown for filled controls that carry white text.
    static let brownFill = Color(light: 0x4A2511, dark: 0x8A4A1C)
    static let brownSoft = Color(light: 0x7A3E12, dark: 0xE8A86A)
    static let cream = Color(light: 0xFFF8E7, dark: 0x2B2118)
    static let ink = Color(light: 0x1F1A17, dark: 0xF2ECE4)
    static let mute = Color(light: 0x6F655C, dark: 0xB3A89C)
    static let line = Color(light: 0xEFE6D6, dark: 0x3A3027)
    static let green = Color(light: 0x1E7F4F, dark: 0x5FCB8E)
    static let red = Color(light: 0xB8372D, dark: 0xF08A80)
    static let amber = Color(light: 0x8F5500, dark: 0xF4C158)

    static func heading(_ style: Font.TextStyle = .headline) -> Font {
        .system(style, design: .rounded, weight: .bold)
    }
}

/// Fixed colours for things drawn on the map. Pins look the same in both modes,
/// like road signs, so they're recognisable at a glance.
enum PinColor {
    static let brown = Color(hex: 0x4A2511)
    static let yellow = Color(hex: 0xF7B500)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    init(_ cl: CLLocationCoordinate2D) { self.init(cl.latitude, cl.longitude) }
}

/// One warm hue from light to dark, in five steps, so higher demand always reads as "more".
enum DemandScale {
    static let steps: [(from: Int, hex: UInt32)] = [
        (22, 0xFCE9B8), (38, 0xF9D27A), (52, 0xF4B63E), (66, 0xEC961C), (78, 0xD96A0E),
    ]
    static let fillAlpha: CGFloat = 0.5

    static func hex(for score: Int) -> UInt32? {
        steps.last { score >= $0.from }?.hex
    }

    static func uiColor(for score: Int) -> UIColor? {
        hex(for: score).map { UIColor(hex: $0, alpha: fillAlpha) }
    }

    static func color(for score: Int) -> Color? {
        hex(for: score).map { Color(hex: $0).opacity(Double(fillAlpha)) }
    }
}

/// Visual style for each kind of pin. A small palette: brown for CDC, gold for suggestions,
/// slate for schools, red for MTR, grey for everything else.
enum PinStyle {
    static func symbol(for kind: PlaceKind) -> String {
        switch kind {
        case .cdcStore: "fork.knife"
        case .university: "graduationcap.fill"
        case .school: "book.closed.fill"
        case .office: "building.2.fill"
        case .mtr: "tram.fill"
        case .rival: "storefront.fill"
        }
    }

    static func hex(for kind: PlaceKind) -> UInt32 {
        switch kind {
        case .cdcStore: 0x4A2511
        case .university, .school: 0x34495E
        case .office: 0x5D6166
        case .mtr: 0xB8372D
        case .rival: 0x8A8178
        }
    }

    static func diameter(for kind: PlaceKind) -> CGFloat {
        switch kind {
        case .cdcStore, .university: 30
        case .rival: 22
        default: 26
        }
    }

    /// What VoiceOver reads for a pin.
    static func accessibilityLabel(for place: Place) -> String {
        let name = place.kind == .cdcStore ? "Café de Coral, \(place.name)" : place.name
        return "\(name), \(place.kind.title)" + (place.isStale ? ", needs a check" : "")
    }
}

/// Round pins drawn once and cached, for Google Maps markers.
enum PinRenderer {
    private static var cache: [String: UIImage] = [:]
    private static var spotCache: [String: (UIImage, CGFloat)] = [:]

    static func image(for kind: PlaceKind) -> UIImage {
        let key = kind.rawValue
        if let cached = cache[key] { return cached }
        let diameter = PinStyle.diameter(for: kind)
        let image = render(width: diameter, height: diameter) { context, origin in
            drawCircle(context, at: origin, diameter: diameter, fill: UIColor(hex: PinStyle.hex(for: kind)),
                       ring: .white)
            drawSymbol(PinStyle.symbol(for: kind), in: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)),
                       pointSize: diameter * 0.42, color: .white)
        }
        cache[key] = image
        return image
    }

    /// A gold letter pin with a score label to its right ("A  83"). Returns the image and the
    /// horizontal anchor (the circle's centre), so the pin sits exactly on its block.
    /// "89", "✓ 89" once approved, and "89 +3" when the pin stands for three more spots nearby.
    static func spotLabel(score: Int, approved: Bool, more: Int) -> String {
        (approved ? "✓ \(score)" : "\(score)") + (more > 0 ? " +\(more)" : "")
    }

    static func spotImage(letter: String, score: Int, selected: Bool, approved: Bool,
                          more: Int = 0) -> (image: UIImage, anchorX: CGFloat) {
        let key = "\(letter)-\(score)-\(selected)-\(approved)-\(more)"
        if let cached = spotCache[key] { return cached }

        let diameter: CGFloat = selected ? 44 : 36
        let label = spotLabel(score: score, approved: approved, more: more)
        let font = UIFont.systemFont(ofSize: 12, weight: .bold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: UIColor(hex: 0x4A2511)])
        let textSize = text.size()
        let pillSize = CGSize(width: textSize.width + 14, height: 20)
        let overlap: CGFloat = 6
        let width = diameter + pillSize.width - overlap

        let image = render(width: width, height: diameter) { context, origin in
            let pillRect = CGRect(x: origin.x + diameter - overlap, y: origin.y + (diameter - pillSize.height) / 2,
                                  width: pillSize.width, height: pillSize.height)
            let pill = UIBezierPath(roundedRect: pillRect, cornerRadius: pillSize.height / 2)
            UIColor.white.setFill()
            pill.fill()
            UIColor(hex: 0x4A2511, alpha: 0.35).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            text.draw(at: CGPoint(x: pillRect.maxX - 7 - textSize.width, y: pillRect.midY - textSize.height / 2))

            drawCircle(context, at: origin, diameter: diameter, fill: UIColor(hex: 0xF7B500), ring: UIColor(hex: 0x4A2511))
            let letterFont = UIFont.systemFont(ofSize: diameter * 0.46, weight: .heavy)
            let letterText = NSAttributedString(string: letter, attributes: [.font: letterFont,
                                                                             .foregroundColor: UIColor(hex: 0x4A2511)])
            let letterSize = letterText.size()
            letterText.draw(at: CGPoint(x: origin.x + diameter / 2 - letterSize.width / 2,
                                        y: origin.y + diameter / 2 - letterSize.height / 2))
        }
        let anchorX = (shadowPad + diameter / 2) / image.size.width
        spotCache[key] = (image, anchorX)
        return (image, anchorX)
    }

    private static let shadowPad: CGFloat = 3

    private static func render(width: CGFloat, height: CGFloat,
                               draw: (CGContext, CGPoint) -> Void) -> UIImage {
        let size = CGSize(width: width + shadowPad * 2, height: height + shadowPad * 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            draw(context.cgContext, CGPoint(x: shadowPad, y: shadowPad))
        }
    }

    private static func drawCircle(_ context: CGContext, at origin: CGPoint, diameter: CGFloat, fill: UIColor, ring: UIColor) {
        let rect = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        ring.setFill()
        UIBezierPath(ovalIn: rect).fill()
        context.restoreGState()
        fill.setFill()
        UIBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
    }

    private static func drawSymbol(_ name: String, in rect: CGRect, pointSize: CGFloat, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let glyph = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        glyph.draw(at: CGPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2))
    }
}

/// The same pins as SwiftUI views, for the Apple Maps fallback and the lists.
struct PinView: View {
    let kind: PlaceKind

    var body: some View {
        let diameter = PinStyle.diameter(for: kind)
        Image(systemName: PinStyle.symbol(for: kind))
            .font(.system(size: diameter * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter - 5, height: diameter - 5)
            .background(Circle().fill(Color(hex: PinStyle.hex(for: kind))))
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

struct SpotPinView: View {
    let letter: String
    let selected: Bool

    var body: some View {
        let diameter: CGFloat = selected ? 44 : 36
        Text(letter)
            .font(.system(size: diameter * 0.46, weight: .heavy))
            .foregroundStyle(PinColor.brown)
            .frame(width: diameter - 5, height: diameter - 5)
            .background(Circle().fill(PinColor.yellow))
            .overlay(Circle().stroke(PinColor.brown, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/// A spot pin with its score label, for the Apple Maps fallback. The label is a background,
/// so it sits behind the circle and the pin's own frame (and its anchor) stays the circle.
struct SpotMapPin: View {
    let spot: Spot
    let selected: Bool
    let approved: Bool
    /// Other spots folded into this pin because they would overlap at this zoom.
    var more = 0

    var body: some View {
        let diameter: CGFloat = selected ? 44 : 36
        SpotPinView(letter: spot.letter, selected: selected)
            .background(alignment: .leading) {
                Text(PinRenderer.spotLabel(score: spot.block.score, approved: approved, more: more))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PinColor.brown)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(.white))
                    .overlay(Capsule().stroke(PinColor.brown.opacity(0.35), lineWidth: 1))
                    .fixedSize()
                    .offset(x: diameter - 11)
            }
    }
}

/// Reads the Google Maps key that Config/Secrets.xcconfig puts into Info.plist.
enum GoogleMapsConfig {
    static var apiKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), trimmed != "YOUR_API_KEY" else { return nil }
        return trimmed
    }

    static var isConfigured: Bool { apiKey != nil }
}

enum ExternalMaps {
    static func googleMapsURL(_ coordinate: Coordinate) -> URL {
        URL(string: "https://www.google.com/maps/search/?api=1&query=\(coordinate.latitude),\(coordinate.longitude)")!
    }

    static func streetViewURL(_ coordinate: Coordinate) -> URL {
        URL(string: "https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=\(coordinate.latitude),\(coordinate.longitude)")!
    }
}
