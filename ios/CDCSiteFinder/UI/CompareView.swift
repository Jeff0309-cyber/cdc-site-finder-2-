import SwiftUI

/// The top picks side by side, with the trade-offs spelled out, the way a good maps app
/// offers two or three routes and explains the difference instead of just picking one.
struct CompareView: View {
    let model: SiteModel

    var body: some View {
        let spots = Array(model.spots.prefix(3))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare the top \(spots.count)").font(Theme.heading(.title3))
                    Text("Best value in each row is in bold.").font(.footnote).foregroundStyle(Theme.mute)
                }

                comparisonTable(spots)

                if let top = spots.first {
                    ForEach(spots.dropFirst()) { spot in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                SpotPinView(letter: spot.letter, selected: false).scaleEffect(0.8)
                                Text("\(spot.letter) compared with \(top.letter)").font(Theme.heading(.subheadline))
                            }
                            ForEach(Explain.tradeOffs(spot, against: top, weights: model.weights), id: \.self) { line in
                                Label(line, systemImage: "arrow.left.arrow.right")
                                    .font(.footnote)
                                    .labelStyle(TradeOffLabelStyle())
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }
                }

                Text("Ranks come from expected new orders after sales taken from existing stores. Confidence shows how much a rank could move if the model's weights are wrong.")
                    .font(.caption)
                    .foregroundStyle(Theme.mute)
            }
            .padding(16)
        }
        .navigationTitle("Compare spots")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func comparisonTable(_ spots: [Spot]) -> some View {
        let rows: [(String, [Double], (Double) -> String, Bool)] = [
            ("Demand score", spots.map { Double($0.block.score) }, { "\(Int($0))" }, true),
            ("New orders a day", spots.map(\.block.netOrders), { "~\(Int($0.rounded()))" }, true),
            ("Taken from CDC", spots.map(\.block.cannibalisation), { Explain.percentText($0) }, false),
            ("Walk from MTR", spots.map { Double(model.directions(to: $0.block.center).walkMinutes ?? 99) }, { "\(Int($0)) min" }, false),
            ("Rent pressure", spots.map { $0.block.features[.rent] ?? 0 }, { level($0) }, false),
            ("Rivals nearby", spots.map { $0.block.features[.rivals] ?? 0 }, { level($0) }, false),
        ]

        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("")
                ForEach(spots) { spot in
                    SpotPinView(letter: spot.letter, selected: false).scaleEffect(0.75).gridColumnAlignment(.center)
                }
            }
            Divider()
            ForEach(rows, id: \.0) { title, values, format, higherIsBetter in
                let best = higherIsBetter ? values.max() : values.min()
                GridRow {
                    Text(title).font(.footnote).foregroundStyle(Theme.mute)
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Text(format(value))
                            .font(.footnote.weight(value == best ? .bold : .regular))
                            .foregroundStyle(Theme.ink)
                            .gridColumnAlignment(.center)
                    }
                }
            }
            GridRow {
                Text("Confidence").font(.footnote).foregroundStyle(Theme.mute)
                ForEach(spots) { spot in
                    ConfidenceChip(level: model.confidence(for: spot.block).level, compact: true, showsIcon: false)
                        .gridColumnAlignment(.center)
                }
            }
            GridRow {
                Text("Start with").font(.footnote).foregroundStyle(Theme.mute)
                ForEach(spots) { spot in
                    Text(spot.format.rawValue).font(.footnote).gridColumnAlignment(.center)
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    private func level(_ value: Double) -> String {
        switch value {
        case ..<0.15: "Very low"
        case ..<0.35: "Low"
        case ..<0.6: "Medium"
        case ..<0.8: "High"
        default: "Very high"
        }
    }
}

private struct TradeOffLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.caption2).foregroundStyle(Theme.mute)
            configuration.title
        }
    }
}
