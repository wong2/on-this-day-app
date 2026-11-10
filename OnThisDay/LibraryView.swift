import Photos
import PhotosUI
import SwiftUI

struct LibraryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = PhotoLibrary()
    @State private var reminder = DailyReminder()
    @State private var reminderNavigationID = UUID()
    @State private var selectedYear: Int?
    @State private var showingInfo = false
    @State private var photoIsZoomed = false
    @State private var yearToast: YearToast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct YearToast: Identifiable {
        let id = UUID()
        let yearsAgo: Int
        var text: String { yearsAgo == 1 ? "1 year ago" : "\(yearsAgo) years ago" }
    }

    var body: some View {
        Group {
            if !library.canRead {
                welcome
            } else if (library.isLoading || library.isCheckingScreenshots) && library.years.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Finding your memories…").foregroundStyle(.secondary)
                }
            } else if library.years.isEmpty {
                emptyLibrary
            } else {
                memories.id(reminderNavigationID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $showingInfo) { LibraryInfoView(library: library, reminder: reminder) }
        .task(id: scenePhase) {
            if scenePhase == .active { await reminder.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task { await reminder.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dailyReminderOpened)) { _ in
            showingInfo = false
            selectedYear = nil
            photoIsZoomed = false
            reminderNavigationID = UUID()
            library.refresh(force: true)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { library.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            library.refresh(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            library.refresh(force: true)
        }
        .onChange(of: library.years) { _, years in
            if !years.contains(where: { $0.year == selectedYear }) { selectedYear = years.first?.year }
        }
        .onChange(of: selectedYear) { previous, current in
            photoIsZoomed = false
            guard let previous, let current, previous != current,
                  library.years.contains(where: { $0.year == previous }) else { return }
            let yearsAgo = MemoryIndex.calendar().component(.year, from: library.today) - current
            guard yearsAgo > 0 else { return }
            let toast = YearToast(yearsAgo: yearsAgo)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { yearToast = toast }
            AccessibilityNotification.Announcement(toast.text).post()
        }
        .onChange(of: photoIsZoomed) { _, zoomed in
            if zoomed { yearToast = nil }
        }
        .onChange(of: library.today) { _, _ in yearToast = nil }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 144, height: 180)
                    .rotationEffect(.degrees(-12))
                    .offset(x: -14, y: -4)
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(width: 144, height: 180)
                    .rotationEffect(.degrees(7))
                Image(systemName: "sun.max")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.orange)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 44)
            Text("A little window\ninto your past.")
                .font(.system(.largeTitle, design: .serif))
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
            Text("Rediscover the photos you took on this day,\nyear after year.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            permissionAction
            Label("Only on your device. Only your memories.", systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var permissionAction: some View {
        switch library.authorization {
        case .notDetermined:
            Button { Task { await library.requestAccess() } } label: {
                Text("Find My Memories").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent).tint(.primary)
        case .restricted:
            Text("Photo access is restricted on this device. Check Screen Time or device management settings.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        default:
            VStack(spacing: 14) {
                Text("Allow photo access in Settings to see your memories.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Settings", action: openAppSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "sun.horizon")
                .font(.system(size: 58, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("A new memory starts today.")
                .font(.system(.title, design: .serif)).multilineTextAlignment(.center)
            Text("No photos from \(library.today.formatted(.dateTime.month(.wide).day())) in past years.\nCome back tomorrow for another look.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if library.authorization == .limited {
                Text("You’ve shared only selected photos. More memories may be waiting in your library.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Choose More Photos", action: presentLimitedPicker)
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            Button("About") { showingInfo = true }
                .font(.footnote).padding(.bottom, 24)
        }
        .padding(28).frame(maxWidth: 520)
    }

    private var memories: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(library.years.enumerated()), id: \.element.id) { index, year in
                        YearStoryView(
                            year: year,
                            years: library.years,
                            today: library.today,
                            isActive: selectedYear == nil ? index == 0 : selectedYear == year.year,
                            olderYear: library.years.indices.contains(index + 1) ? library.years[index + 1].year : nil,
                            selectYear: { selectedYear = $0 },
                            showInfo: { showingInfo = true },
                            photoIsZoomed: $photoIsZoomed
                        )
                        .containerRelativeFrame(.vertical)
                        .id(year.year)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedYear)
            .scrollDisabled(photoIsZoomed)
            .clipped()
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.045))
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let yearToast {
                Text(yearToast.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.top, 60)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: yearToast?.id) {
            guard yearToast != nil else { return }
            do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { yearToast = nil }
        }
    }
}

struct YearStoryView: View {
    let year: MemoryYear
    let years: [MemoryYear]
    let today: Date
    let isActive: Bool
    let olderYear: Int?
    let selectYear: (Int) -> Void
    let showInfo: () -> Void
    @Binding var photoIsZoomed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPhoto: String?
    @State private var cityStore = PhotoCityStore.shared
    @State private var share = PhotoShareLoader()

    private var photoIndex: Int { year.photos.firstIndex(where: { $0.id == selectedPhoto }) ?? 0 }
    private var cityCoordinates: [MemoryCoordinate] {
        guard isActive else { return [] }
        var coordinates = [photoIndex, photoIndex + 1, photoIndex - 1].compactMap { index in
            year.photos.indices.contains(index) ? year.photos[index].coordinate : nil
        }
        if let yearIndex = years.firstIndex(where: { $0.year == year.year }) {
            for index in [yearIndex + 1, yearIndex - 1] where years.indices.contains(index) {
                if let coordinate = years[index].photos.first?.coordinate { coordinates.append(coordinate) }
            }
        }
        return coordinates
    }
    private var progressRange: Range<Int> {
        let start = min(max(photoIndex - 9, 0), max(year.photos.count - 20, 0))
        return start..<min(start + 20, year.photos.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(years) { item in
                        Button(String(item.year)) { selectYear(item.year) }
                    }
                    Divider()
                    Button("About", systemImage: "info.circle", action: showInfo)
                } label: {
                    HStack(spacing: 6) {
                        Text(String(year.year)).font(.title3.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Year \(String(year.year)). Years and About")
                .disabled(photoIsZoomed)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(today.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)

            HStack(spacing: 4) {
                ForEach(progressRange, id: \.self) { index in
                    Capsule().fill(index <= photoIndex ? Color.white : Color.white.opacity(0.2))
                        .frame(height: 2)
                }
            }
            .accessibilityHidden(true)
            .padding(.horizontal, 16).padding(.bottom, 6)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(year.photos) { photo in
                        PhotoView(
                            photo: photo,
                            isActive: isActive && photo.id == year.photos[photoIndex].id,
                            previous: { movePhoto(-1) }, next: { movePhoto(1) },
                            zoomChanged: { photoIsZoomed = $0 }
                        )
                            .containerRelativeFrame(.horizontal)
                            .id(photo.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedPhoto)
            .scrollDisabled(photoIsZoomed)
            .clipped()

            HStack(spacing: 12) {
                Text("\(photoIndex + 1) / \(year.photos.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Photo \(photoIndex + 1) of \(year.photos.count)")
                    .fixedSize()
                PhotoCityLabel(city: cityStore.cachedCity(for: year.photos[photoIndex].coordinate))
                    .frame(maxWidth: .infinity)
                    .opacity(photoIsZoomed ? 0 : 1)
                    .accessibilityHidden(photoIsZoomed)
                Button { share.prepare(id: year.photos[photoIndex].id) } label: {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary).frame(width: 44, height: 44)
                }
                .disabled(share.isPreparing)
                .accessibilityLabel("Share photo")
            }
            .disabled(photoIsZoomed)
            .padding(.leading, 16)
            .padding(.trailing, 8)
        }
        .task(id: cityCoordinates) {
            await cityStore.load(cityCoordinates)
        }
        .overlay(alignment: .bottom) {
            if share.isPreparing {
                HStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(share.progress > 0 ? "Downloading photo… \(Int(share.progress * 100))%" : "Preparing photo…")
                        .font(.footnote)
                    Spacer()
                    Button("Cancel", action: share.cancelPreparation).frame(minHeight: 44)
                }
                .padding(.horizontal, 16)
                .background(.regularMaterial)
            }
        }
        .sheet(item: $share.file, onDismiss: share.finishSharing) { file in
            PhotoShareSheet(fileURL: file.url)
        }
        .alert("Couldn’t Share Photo", isPresented: Binding(
            get: { share.errorMessage != nil },
            set: { if !$0 { share.errorMessage = nil } }
        )) {
            Button("Try Again") { share.prepare(id: year.photos[photoIndex].id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(share.errorMessage ?? "Please try again.")
        }
        .onChange(of: year.photos[photoIndex].id) { _, _ in share.cancelPreparation() }
        .onChange(of: isActive) { _, active in
            if !active { share.cancelPreparation() }
        }
        .onDisappear { share.cancelPreparation() }
        .onChange(of: year.photos) { _, photos in
            if !photos.contains(where: { $0.id == selectedPhoto }) { selectedPhoto = photos.first?.id }
        }
        .onChange(of: selectedPhoto) { _, _ in
            if isActive { photoIsZoomed = false }
        }
        .accessibilityHidden(!isActive)
        .accessibilityAction(named: "Older year") {
            if let olderYear, !photoIsZoomed { selectYear(olderYear) }
        }
    }

    private func movePhoto(_ offset: Int) {
        let nextIndex = photoIndex + offset
        guard !photoIsZoomed, year.photos.indices.contains(nextIndex) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            selectedPhoto = year.photos[nextIndex].id
        }
    }
}

struct LibraryInfoView: View {
    let library: PhotoLibrary
    let reminder: DailyReminder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Daily Reminder", isOn: Binding(
                        get: { reminder.isEnabled },
                        set: { enabled in Task { await reminder.setEnabled(enabled) } }
                    ))
                    DatePicker("Time", selection: Binding(
                        get: { reminder.time },
                        set: { time in Task { await reminder.setTime(time) } }
                    ), displayedComponents: .hourAndMinute)
                    if reminder.authorization == .denied {
                        Text("Notifications are off in iOS Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Open Notification Settings") {
                            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                    }
                    if let error = reminder.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task {
                                if reminder.isEnabled { await reminder.refresh() }
                                else { await reminder.setEnabled(true) }
                            }
                        }
                    }
                } footer: {
                    Text("A daily nudge at your local time.")
                }
                .disabled(reminder.isUpdating)
                Section("Gestures") {
                    Label("Tap or swipe to browse", systemImage: "hand.tap")
                    Label("Swipe vertically to change years", systemImage: "arrow.up.arrow.down")
                    Label("Pinch to zoom; double-tap to reset", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Section("Photo access") {
                    LabeledContent("Access", value: library.authorization == .limited ? "Selected Photos" : "Full Library")
                    if library.authorization == .limited {
                        Button("Choose More Photos", action: presentLimitedPicker)
                    }
                    Button("Open Settings", action: openAppSettings)
                }
                Section {
                    Toggle("AI Screenshot Filter", isOn: Binding(
                        get: { library.filterAIScreenshots },
                        set: { library.filterAIScreenshots = $0 }
                    ))
                    if library.isCheckingScreenshots {
                        Label("Checking screenshots…", systemImage: "sparkles")
                    } else if library.uncheckedPhotoCount > 0 {
                        Button("Retry Screenshot Check") { library.refresh(force: true) }
                    }
                } footer: {
                    Text("AI runs on-device. Turn off to show AI-filtered photos.")
                }
                Section("Privacy") {
                    Text("Photos stay on your device unless you share them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("On This Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

@MainActor
private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}

@MainActor
private func presentLimitedPicker() {
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
          var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
    while let presented = controller.presentedViewController { controller = presented }
    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
}
