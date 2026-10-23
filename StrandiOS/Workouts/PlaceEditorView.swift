import SwiftUI
import MapKit
import StrandDesign

/// Pin a place on the map, name it, and choose what gets tracked there.
struct PlaceEditorView: View {
    @State private var place: WorkoutPlace
    private let isNew: Bool
    @ObservedObject private var tracker = AutoWorkoutTracker.shared
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var locating = false
    @State private var confirmDelete = false

    init(place: WorkoutPlace?) {
        let p = place ?? WorkoutPlace(name: "", latitude: 0, longitude: 0, sport: "Strength",
                                      marginBPM: 20, quietEndMin: 10)
        _place = State(initialValue: p)
        isNew = place == nil
        if place != nil {
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                latitudinalMeters: max(600, p.radiusM * 5), longitudinalMeters: max(600, p.radiusM * 5))))
        }
    }

    private var pinned: Bool { place.latitude != 0 || place.longitude != 0 }
    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    var body: some View {
        Form {
            Section {
                map
                    .frame(height: 280)
                    .listRowInsets(EdgeInsets())
                HStack {
                    TextField("Search, e.g. rink, gym name", text: $query)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit(search)
                    if searching { ProgressView() }
                }
                ForEach(results, id: \.self) { item in
                    Button {
                        pick(item)
                    } label: {
                        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                            Text(item.name ?? String(localized: "Unnamed place"))
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                            if let addr = item.placemark.title {
                                Text(addr)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Button {
                    useMyLocation()
                } label: {
                    Label(locating ? "Finding you…" : "Pin where I am now", systemImage: "location.fill")
                }
                .disabled(locating)
            } footer: {
                Text("Tap the map to drop the pin. The circle is the area that counts as being there.")
            }

            Section("Details") {
                TextField("Name, e.g. Gym, Rink", text: $place.name)
                Picker("Sport", selection: $place.sport) {
                    ForEach(WorkoutCatalog.all.map(\.name), id: \.self) { name in
                        Text(LocalizedStringKey(name)).tag(name)
                    }
                }
                .pickerStyle(.navigationLink)
                .onChange(of: place.sport) { _, sport in
                    guard isNew else { return }
                    let d = WorkoutPlace.defaults(for: sport)
                    place.marginBPM = d.marginBPM
                    place.quietEndMin = d.quietEndMin
                }
                Stepper(value: $place.radiusM, in: AutoTrackingPrefs.minRadiusM...AutoTrackingPrefs.maxRadiusM,
                        step: 25) {
                    Text("Area: \(Int(place.radiusM)) m around the pin")
                }
            }

            Section {
                Stepper(value: $place.marginBPM, in: 8...60, step: 2) {
                    Text("Start when heart rate is \(place.marginBPM)+ above resting")
                }
                Stepper(value: $place.quietEndMin, in: 3...45) {
                    Text("Stop after \(place.quietEndMin) min of low heart rate")
                }
            } header: {
                Text("When to start and stop")
            } footer: {
                Text("Leaving also stops it, timed to when your heart rate last dropped. Lifting barely moves heart rate between sets, so it needs a lower start line than games like hockey.")
            }

            if !isNew {
                Section {
                    Button("Delete place", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(isNew ? "New place" : place.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var p = place
                    p.name = p.name.trimmingCharacters(in: .whitespaces)
                    tracker.savePlace(p)
                    dismiss()
                }
                .disabled(!pinned || place.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Delete \(place.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                tracker.deletePlace(id: place.id)
                dismiss()
            }
        }
        .onAppear {
            if !pinned { useMyLocation(movePinToo: false) }
        }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if pinned {
                    MapCircle(center: coordinate, radius: place.radiusM)
                        .foregroundStyle(StrandPalette.accent.opacity(0.18))
                        .stroke(StrandPalette.accent, lineWidth: 2)
                    Marker(place.name.isEmpty ? String(localized: "Place") : place.name, coordinate: coordinate)
                        .tint(StrandPalette.accent)
                }
                UserAnnotation()
            }
            .mapControls { MapUserLocationButton() }
            .onTapGesture { point in
                if let c = proxy.convert(point, from: .local) {
                    place.latitude = c.latitude
                    place.longitude = c.longitude
                }
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        let center = pinned ? coordinate : tracker.lastKnownLocation
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                searching = false
                results = Array((response?.mapItems ?? []).prefix(6))
            }
        }
    }

    private func pick(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        place.latitude = c.latitude
        place.longitude = c.longitude
        if place.name.isEmpty, let n = item.name { place.name = n }
        results = []
        query = ""
        camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: max(600, place.radiusM * 5),
                                            longitudinalMeters: max(600, place.radiusM * 5)))
    }

    private func useMyLocation(movePinToo: Bool = true) {
        locating = true
        tracker.requestCurrentLocation { loc in
            locating = false
            guard let loc else { return }
            if movePinToo {
                place.latitude = loc.coordinate.latitude
                place.longitude = loc.coordinate.longitude
            }
            camera = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 800,
                                                longitudinalMeters: 800))
        }
    }
}
