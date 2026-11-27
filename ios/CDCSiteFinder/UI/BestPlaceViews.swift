import SwiftUI

/// The answer to "where should CDC open next?", at the top of the sheet.
struct BestPlaceCard: View {
    let model: SiteModel
    let spot: Spot

    var body: some View {
        let block = spot.block
        let confidence = model.confidence(for: block)
        let district = AreaData.districts[block.district]
        let directions = model.directions(to: block.center)
        VStack(alignment: .leading, spacing: 10) {
            Text("Best place to open next")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.brown)
                .textCase(.uppercase)

            HStack(alignment: .top, spacing: 12) {
                SpotPinView(letter: spot.letter, selected: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(directions.short).font(Theme.heading(.title3)).foregroundStyle(Theme.ink)
                    Text("\(district.title) · \(district.nameZH) · \(spot.kind.rawValue)")
                        .font(.footnote)
                        .foregroundStyle(Theme.mute)
                }
            }

            HStack(spacing: 16) {
                MiniStat(value: "\(block.score)", label: "score / 100")
                MiniStat(value: "~\(Int(block.netOrders.rounded()))", label: "new orders a day")
                MiniStat(value: Geo.roughCount(block.catchment), label: "people in 5 min walk")
            }

            Text(model.why(block)).font(.footnote).foregroundStyle(Theme.ink)

            HStack(spacing: 8) {
                ConfidenceChip(level: confidence.level)
                if confidence.coverageNote != nil {
                    Label("Check for a nearby branch first", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                }
            }

            HStack(spacing: 10) {
                Button { model.open(.spot(spot.id)) } label: {
                    Label("Why here", systemImage: "lightbulb").frame(maxWidth: .infinity).frame(height: 38)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brownFill)
                Button { model.open(.districts) } label: {
                    Label("All 18 districts", systemImage: "list.number").frame(maxWidth: .infinity).frame(height: 38)
                }
                .buttonStyle(.bordered)
                .tint(Theme.brown)
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(14)
        .background(Theme.cream, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

/// Every district, ranked by its best spot, with how well its CDC stores are mapped.
struct DistrictRankingView: View {
    let model: SiteModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Districts ranked by their best spot").font(Theme.heading(.title3))
                    Text("New orders a day at the best block in each district, after sales taken from existing stores.")
                        .font(.footnote)
                        .foregroundStyle(Theme.mute)
                }

                VStack(spacing: 0) {
                    ForEach(Array(model.districtRows.enumerated()), id: \.element.id) { index, row in
                        Button {
                            if let block = row.best {
                                model.open(model.spot(forBlock: block.id) != nil ? .spot(block.id) : .block(block.id))
                            }
                        } label: {
                            DistrictRowView(rank: index + 1, row: row)
                        }
                        .buttonStyle(.plain)
                        .disabled(row.best == nil)
                        if row.id != model.districtRows.last?.id { Divider().padding(.leading, 44) }
                    }
                }
                .cardStyle()

                Text("Stores mapped: \(model.data.stores.count) locations from the published branch list (May 2023), the team's 30 checked branches and OpenStreetMap, against about \(AreaData.estimatedStoreTotal) Café de Coral stores today. Districts marked with a warning have fewer than 60% of their likely stores mapped, so their gaps may be data gaps.")
                    .font(.caption)
                    .foregroundStyle(Theme.mute)
            }
            .padding(16)
        }
        .navigationTitle("Districts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DistrictRowView: View {
    let rank: Int
    let row: DistrictRow

    var body: some View {
        let coverage = row.expectedStores > 0 ? Double(row.mappedStores) / row.expectedStores : 1
        HStack(alignment: .top, spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.brown)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.district.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(row.district.nameZH).font(.caption).foregroundStyle(Theme.mute)
                    if let spot = row.bestSpot {
                        Text("Spot \(spot.letter)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PinColor.brown)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(PinColor.yellow, in: Capsule())
                    }
                }
                Text("\(row.district.population.formatted()) people · \(Geo.roughCount(row.underserved)) more than 5 min from a mapped CDC")
                    .font(.caption)
                    .foregroundStyle(Theme.mute)
                HStack(spacing: 4) {
                    if coverage < 0.6 {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                    }
                    // Districts with offices or malls can have more stores than their population suggests.
                    Text(row.mappedStores >= Int(row.expectedStores.rounded())
                         ? "\(row.mappedStores) CDC stores mapped"
                         : "\(row.mappedStores) of ~\(Int(row.expectedStores.rounded())) stores mapped")
                        .foregroundStyle(coverage < 0.6 ? Theme.amber : Theme.mute)
                }
                .font(.caption2.weight(.semibold))
            }
            Spacer(minLength: 8)
            if let best = row.best {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("~\(Int(best.netOrders.rounded()))/day").font(.subheadline.weight(.bold)).foregroundStyle(Theme.brownSoft)
                    Text("score \(best.score)").font(.caption).foregroundStyle(Theme.mute)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
