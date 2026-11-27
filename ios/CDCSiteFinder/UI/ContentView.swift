import SwiftUI

struct ContentView: View {
    @Bindable var model: SiteModel
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var screenHeight: CGFloat = 852

    private let usesGoogle = GoogleMapsConfig.isConfigured

    /// The parts of the map covered by the search bar and chips (top) and the sheet (bottom). The maps
    /// centre camera moves in what's left, so a selected spot sits above the sheet, not under it.
    private var mapInsets: EdgeInsets {
        let sheet = model.detent == SheetDetent.peek ? SheetDetent.peekHeight : screenHeight / 2
        return EdgeInsets(top: 150, leading: 0, bottom: sheet + 8, trailing: 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }

            VStack(alignment: .leading, spacing: 10) {
                SearchBar(text: $searchText, focused: $searchFocused)
                if searchFocused || !searchText.isEmpty {
                    searchPanel
                } else {
                    LayerChips(model: model)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            if model.layers.contains(.demand) { DemandLegend() }
                            if model.hiddenPinCount > 0 {
                                Label("\(model.hiddenPinCount) pins hidden · zoom in", systemImage: "plus.magnifyingglass")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(.regularMaterial, in: Capsule())
                                    .accessibilityLabel("\(model.hiddenPinCount) pins hidden to avoid overlap. Zoom in to see them.")
                            }
                        }
                        Spacer()
                        MapButtons(model: model)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.horizontal, 24)
                    .padding(.top, 112)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .sheet(isPresented: .constant(true)) {
            SheetRoot(model: model, usesGoogle: usesGoogle)
                .presentationDetents([SheetDetent.peek, .medium, .large], selection: $model.detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationCornerRadius(22)
                // Solid, not translucent: grey text stays readable over the bright demand colours.
                .presentationBackground(Color(.systemBackground))
                .interactiveDismissDisabled()
                .sheet(item: $model.controlTab) { tab in ControlCenterView(model: model, initialTab: tab) }
        }
    }

    @ViewBuilder private var map: some View {
        if usesGoogle {
            GoogleSiteMap(model: model, scoreVersion: model.scoreVersion, layers: model.layers,
                          selection: model.selection, camera: model.cameraRequest,
                          showsUserLocation: model.location.isAuthorized,
                          padding: UIEdgeInsets(top: mapInsets.top, left: 0, bottom: mapInsets.bottom, right: 0))
        } else {
            AppleSiteMap(model: model, insets: mapInsets)
        }
    }

    @ViewBuilder private var searchPanel: some View {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            RecentSearchesList(model: model) { result in finishSearch(with: result) }
        } else {
            SearchResultsList(results: model.search(searchText)) { result in finishSearch(with: result) }
        }
    }

    private func finishSearch(with result: SearchResult) {
        model.choose(result)
        searchText = ""
        searchFocused = false
    }
}

struct SearchBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.mute)
            TextField("Search spots, stores, schools, MTR", text: $text)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty || focused.wrappedValue {
                Button {
                    text = ""
                    focused.wrappedValue = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.mute)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

struct SearchResultsList: View {
    let results: [SearchResult]
    let choose: (SearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text("Try a district (Mong Kok), a school (CityU), an MTR station or 旺角")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mute)
                    .padding(14)
            }
            ForEach(results) { result in
                SearchRow(result: result, choose: choose)
                if result.id != results.last?.id { Divider().padding(.leading, 56) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

struct RecentSearchesList: View {
    let model: SiteModel
    let choose: (SearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.recentSearches.isEmpty {
                Text("Search by name, abbreviation (CityU, MK), address (Nathan Road) or Chinese (旺角). Typos are fine.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mute)
                    .padding(14)
            } else {
                HStack {
                    Text("Recent").font(.caption.weight(.bold)).foregroundStyle(Theme.mute)
                    Spacer()
                    Button("Clear") { model.clearRecentSearches() }.font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)
                ForEach(model.recentSearches) { result in
                    SearchRow(result: result, choose: choose, recent: true)
                    if result.id != model.recentSearches.last?.id { Divider().padding(.leading, 56) }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

struct SearchRow: View {
    let result: SearchResult
    let choose: (SearchResult) -> Void
    var recent = false

    var body: some View {
        Button { choose(result) } label: {
            HStack(spacing: 12) {
                Image(systemName: recent ? "clock.arrow.circlepath" : result.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(result.symbol == "star.fill" && !recent ? PinColor.yellow : Theme.brownFill))
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(result.subtitle).font(.caption).foregroundStyle(Theme.mute)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LayerChips: View {
    let model: SiteModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MapLayer.allCases) { layer in
                    let on = model.layers.contains(layer)
                    Button { model.toggle(layer) } label: {
                        Label(layer.title, systemImage: layer.symbol)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .foregroundStyle(on ? .white : Theme.ink)
                            .background(Capsule().fill(on ? AnyShapeStyle(Theme.brownFill) : AnyShapeStyle(.regularMaterial)))
                            .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct DemandLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Demand score").font(.caption2.weight(.bold)).foregroundStyle(Theme.ink)
            HStack(spacing: 2) {
                ForEach(DemandScale.steps, id: \.from) { step in
                    Rectangle().fill(Color(hex: step.hex)).frame(width: 18, height: 8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            HStack {
                Text("Low"); Spacer(); Text("High")
            }
            .font(.caption2)
            .foregroundStyle(Theme.mute)
            .frame(width: 98)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demand score legend, from low (light yellow) to high (dark orange)")
    }
}

struct MapButtons: View {
    let model: SiteModel

    var body: some View {
        VStack(spacing: 0) {
            Button { model.recenter() } label: {
                Image(systemName: "scope").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Show the whole area")
            Divider().frame(width: 30)
            Button { model.locateMe() } label: {
                Image(systemName: model.location.isAuthorized ? "location.fill" : "location").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Show where I am")
            Divider().frame(width: 30)
            Button { model.controlTab = model.pendingReports.isEmpty ? .model : .reviews } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if !model.pendingReports.isEmpty {
                            Text("\(model.pendingReports.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(Capsule().fill(Theme.red))
                                .offset(x: -3, y: 4)
                        }
                    }
            }
            .accessibilityLabel(model.pendingReports.isEmpty ? "Model, data and quality"
                                : "Model, data and quality. \(model.pendingReports.count) reports waiting for review")
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(Theme.brown)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.message, systemImage: toast.symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
