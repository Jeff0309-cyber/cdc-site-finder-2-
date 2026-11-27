#if DEBUG
import Foundation

/// Debug-only launch arguments for screenshots and demos, for example:
///
///     -demoReset                    start from the first-launch state
///     -demoPilots 2                 run two pilot rounds
///     -demoOpen spot:1              open the shortlist's first spot (also: compare, districts, place:<id>, block:<lat>,<lon>)
///     -demoControl reviews          open a tab of the control centre (model, data, reviews, quality)
///     -demoApproveReports 1         approve the first N pending reports
///     -demoDetent large             sheet height: peek, medium or large
enum DemoLaunch {
    /// Runs before the model is created.
    static func prepare() {
        if ProcessInfo.processInfo.arguments.contains("-demoReset") {
            SiteModel.clearSavedState()
        }
    }

    static func apply(to model: SiteModel) {
        let defaults = UserDefaults.standard

        let pilots = defaults.integer(forKey: "demoPilots")
        if pilots > 0 { for _ in 0..<pilots { model.runPilot() } }

        let approvals = defaults.integer(forKey: "demoApproveReports")
        if approvals > 0 {
            for report in model.pendingReports.prefix(approvals) { model.approve(report) }
        }

        if let open = defaults.string(forKey: "demoOpen") {
            let parts = open.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts.first {
            case "spot":
                let rank = Int(parts.last ?? "1") ?? 1
                if model.spots.indices.contains(rank - 1) { model.open(.spot(model.spots[rank - 1].id)) }
            case "compare":
                model.open(.compare)
            case "districts":
                model.open(.districts)
            case "place":
                if let id = parts.last { model.open(.place(id)) }
            case "block":
                let numbers = (parts.last ?? "").split(separator: ",").compactMap { Double($0) }
                if numbers.count == 2, let id = SiteEngine.Grid.id(at: Coordinate(numbers[0], numbers[1])) {
                    model.open(model.spot(forBlock: id) != nil ? .spot(id) : .block(id))
                }
            default:
                break
            }
        }

        switch defaults.string(forKey: "demoDetent") {
        case "large": model.detent = .large
        case "medium": model.detent = .medium
        case "peek": model.detent = SheetDetent.peek
        default: break
        }

        if let tab = defaults.string(forKey: "demoControl").flatMap(ControlTab.init(rawValue:)) {
            model.controlTab = tab
        }
    }
}
#endif
