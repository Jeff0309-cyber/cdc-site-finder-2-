import CoreGraphics

/// Decides which place pins to draw so none overlap, the way map renderers place labels:
/// go through pins in priority order and skip any that would collide with one already placed.
/// The order is fixed (priority, then id), so the same view always shows the same pins and
/// nothing jumps while you pan.
enum PinLayout {
    /// Minimum distance between pin centres, in points. Pins are 22–30 pt wide.
    static let spacing: CGFloat = 30

    struct Candidate {
        let id: String
        let kind: PlaceKind
        let point: CGPoint
    }

    struct Result: Equatable {
        let visible: Set<String>
        /// Pins inside the screen that were hidden to avoid overlap.
        let hiddenOnScreen: Int
    }

    /// - Parameters:
    ///   - reserved: points already taken, such as shortlist pins and their score labels.
    ///   - alwaysShow: ids that must stay visible, such as the selected place.
    static func visible(_ candidates: [Candidate], reserved: [CGPoint], bounds: CGRect,
                        alwaysShow: Set<String> = [], spacing: CGFloat = spacing) -> Result {
        var placed = reserved
        var visible: Set<String> = []
        var hidden = 0

        let forced = candidates.filter { alwaysShow.contains($0.id) }
        for candidate in forced {
            visible.insert(candidate.id)
            placed.append(candidate.point)
        }

        let ordered = candidates
            .filter { !alwaysShow.contains($0.id) }
            .sorted { ($0.kind.priority, $0.id) < ($1.kind.priority, $1.id) }
        for candidate in ordered {
            guard bounds.contains(candidate.point) else {
                // Off screen: the map culls it anyway, and it shouldn't block anything on screen.
                visible.insert(candidate.id)
                continue
            }
            let clear = placed.allSatisfy { hypot($0.x - candidate.point.x, $0.y - candidate.point.y) >= spacing }
            if clear {
                visible.insert(candidate.id)
                placed.append(candidate.point)
            } else {
                hidden += 1
            }
        }
        return Result(visible: visible, hiddenOnScreen: hidden)
    }

    /// A spot pin is a 36–44 pt circle with its score label to the right: about 86 × 44 pt in all.
    static let spotFootprint = CGSize(width: 86, height: 44)

    /// Zoomed out over all of Hong Kong, nearby spots would pile on top of each other. Spot pins that
    /// would overlap fold into the best-ranked one, which then shows "+N"; zooming in separates them.
    /// - Parameters:
    ///   - spots: spot ids and their screen points, best first.
    ///   - keep: a spot that always keeps its own pin, such as the selected one.
    /// - Returns: each spot that keeps a pin, with how many other spots it stands for.
    static func groupSpots(_ spots: [(id: Int, point: CGPoint)], keep: Int? = nil) -> [Int: Int] {
        var leaders: [(id: Int, point: CGPoint)] = []
        var counts: [Int: Int] = [:]
        let ordered = spots.filter { $0.id == keep } + spots.filter { $0.id != keep }
        for spot in ordered {
            let leader = leaders.first { leader in
                abs(leader.point.x - spot.point.x) < spotFootprint.width
                    && abs(leader.point.y - spot.point.y) < spotFootprint.height
            }
            if let leader {
                counts[leader.id, default: 0] += 1
            } else {
                leaders.append(spot)
                counts[spot.id] = 0
            }
        }
        return counts
    }
}
