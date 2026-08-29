import SwiftUI

struct HealthDataViewerView: View {
    @EnvironmentObject private var coordinator: HealthExportCoordinator
    @State private var state: SnapshotViewState = .loading
    @State private var period: HealthDataPeriod = .today
    @State private var isRefreshingFromHealth = false
    @State private var refreshError: String?

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView(L10n.text("viewer.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            case .loaded(let snapshot):
                viewer(snapshot)
            case .unavailable:
                unavailableState
            case .failed:
                unavailableState
            }
        }
        .navigationTitle(L10n.text("viewer.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshFromHealth() }
                } label: {
                    if isRefreshingFromHealth {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isRefreshingFromHealth)
                .accessibilityLabel(L10n.text("viewer.action.update"))
            }
        }
        .task {
            await loadSnapshot()
        }
        .onChange(of: coordinator.lastSyncDate) { _, _ in
            guard !isRefreshingFromHealth else { return }
            Task { await loadSnapshot(showLoading: false) }
        }
    }

    private func viewer(_ snapshot: HealthDataSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                header(snapshot)

                if let refreshError {
                    Label(refreshError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Picker(L10n.text("viewer.period.accessibility"), selection: $period) {
                    ForEach(HealthDataPeriod.allCases) { option in
                        Text(ViewerPresentation.periodTitle(option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("health-data-period-picker")

                if !snapshot.profile.isEmpty {
                    NavigationLink {
                        ProfileDetailView(profile: snapshot.profile)
                    } label: {
                        ViewerNavigationCard(
                            title: L10n.text("viewer.section.profile"),
                            subtitle: L10n.text("viewer.profile.caption"),
                            symbol: "person.text.rectangle.fill",
                            color: .indigo
                        )
                    }
                    .buttonStyle(.plain)
                }

                metricSections(snapshot)
                categorySections(snapshot)
                activitySection(snapshot)
                sleepSection(snapshot)
                workoutSection(snapshot)
                specialSections(snapshot)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await loadSnapshot()
        }
    }

    private func header(_ snapshot: HealthDataSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "list.bullet.rectangle.portrait.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.teal)
                .frame(width: 54, height: 54)
                .background(.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("viewer.hero.title"))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("viewer.hero.caption"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await refreshFromHealth() }
                } label: {
                    if isRefreshingFromHealth {
                        Label {
                            Text(L10n.text("viewer.updating"))
                        } icon: {
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Label(L10n.text("viewer.action.update"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshingFromHealth)

                if let date = snapshot.generatedDate {
                    Label(
                        L10n.format("viewer.snapshot.updated", L10n.compactDateTime(date)),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func metricSections(_ snapshot: HealthDataSnapshot) -> some View {
        ForEach(metricGroups(snapshot), id: \.id) { group in
            ViewerSectionCard(
                title: ViewerPresentation.groupTitle(group.id),
                symbol: group.symbol,
                color: group.color
            ) {
                ForEach(group.items) { item in
                    NavigationLink {
                        MetricDetailView(metric: item.metric, key: item.key, period: period)
                    } label: {
                        MetricSummaryRow(metric: item.metric, key: item.key, period: period)
                    }
                    .buttonStyle(.plain)
                    if item.id != group.items.last?.id {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func categorySections(_ snapshot: HealthDataSnapshot) -> some View {
        let items = snapshot.categories.map { ViewerCategoryItem(key: $0.key, category: $0.value) }
            .sorted { ViewerPresentation.category($0.key).title < ViewerPresentation.category($1.key).title }
        if !items.isEmpty {
            ViewerSectionCard(
                title: L10n.text("viewer.section.events"),
                symbol: "checklist.checked",
                color: .orange
            ) {
                ForEach(items) { item in
                    NavigationLink {
                        CategoryDetailView(category: item.category, key: item.key, period: period)
                    } label: {
                        CategorySummaryRow(category: item.category, key: item.key, period: period)
                    }
                    .buttonStyle(.plain)
                    if item.id != items.last?.id {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activitySection(_ snapshot: HealthDataSnapshot) -> some View {
        if !snapshot.activityRings.isEmpty {
            let count = snapshot.activityRings.filter { period.includes($0.parsedDate) }.count
            NavigationLink {
                ActivityRingDetailView(rings: snapshot.activityRings, period: period)
            } label: {
                ViewerNavigationCard(
                    title: L10n.text("viewer.section.activity"),
                    subtitle: count == 0
                        ? L10n.text("viewer.empty.period")
                        : L10n.format("viewer.activity.count", count),
                    symbol: "figure.run.circle.fill",
                    color: .pink
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func sleepSection(_ snapshot: HealthDataSnapshot) -> some View {
        let intervals = snapshot.parsedSleepIntervals
        if !intervals.isEmpty {
            let count = intervals.filter { period.includes($0.startDate) }.count
            NavigationLink {
                SleepDetailView(intervals: intervals, period: period)
            } label: {
                ViewerNavigationCard(
                    title: L10n.text("viewer.section.sleep"),
                    subtitle: count == 0
                        ? L10n.text("viewer.empty.period")
                        : L10n.format("viewer.sleep.count", count),
                    symbol: "bed.double.fill",
                    color: .indigo
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func workoutSection(_ snapshot: HealthDataSnapshot) -> some View {
        if !snapshot.workouts.isEmpty {
            let count = snapshot.workouts.filter { period.includes($0.startDate) }.count
            NavigationLink {
                WorkoutDetailView(workouts: snapshot.workouts, period: period)
            } label: {
                ViewerNavigationCard(
                    title: L10n.text("viewer.section.workouts"),
                    subtitle: count == 0
                        ? L10n.text("viewer.empty.period")
                        : L10n.format("viewer.workout.count", count),
                    symbol: "figure.run.circle.fill",
                    color: .mint
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func specialSections(_ snapshot: HealthDataSnapshot) -> some View {
        let records = snapshot.special
            .map { ViewerSpecialItem(key: $0.key, records: $0.value) }
            .sorted { ViewerPresentation.special($0.key).title < ViewerPresentation.special($1.key).title }
        if !records.isEmpty {
            ViewerSectionCard(
                title: L10n.text("viewer.section.special"),
                symbol: "heart.text.clipboard.fill",
                color: .red
            ) {
                ForEach(records) { item in
                    NavigationLink {
                        SpecialRecordDetailView(records: item.records, key: item.key, period: period)
                    } label: {
                        let presentation = ViewerPresentation.special(item.key)
                        ViewerSimpleRow(
                            title: presentation.title,
                            subtitle: ViewerPresentation.countText(item.records.filter { period.includes($0.startDate) }.count),
                            symbol: presentation.symbol,
                            color: presentation.color
                        )
                    }
                    .buttonStyle(.plain)
                    if item.id != records.last?.id {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
    }

    private func metricGroups(_ snapshot: HealthDataSnapshot) -> [ViewerMetricGroup] {
        let grouped = Dictionary(grouping: snapshot.metrics.map { ViewerMetricItem(key: $0.key, metric: $0.value) }) {
            ViewerPresentation.metric($0.key).group
        }
        return ViewerPresentation.metricGroupOrder.compactMap { groupID in
            guard let items = grouped[groupID], !items.isEmpty else { return nil }
            let visual = ViewerPresentation.groupVisual(groupID)
            return ViewerMetricGroup(
                id: groupID,
                symbol: visual.symbol,
                color: visual.color,
                items: items.sorted { ViewerPresentation.metric($0.key).title < ViewerPresentation.metric($1.key).title }
            )
        }
    }

    private var unavailableState: some View {
        ContentUnavailableView {
            Label(L10n.text("viewer.unavailable.title"), systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(L10n.text("viewer.unavailable.caption"))
        } actions: {
            Button(L10n.text("viewer.action.update")) {
                Task { await refreshFromHealth() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRefreshingFromHealth)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func refreshFromHealth() async {
        guard !isRefreshingFromHealth else { return }
        isRefreshingFromHealth = true
        refreshError = nil
        defer { isRefreshingFromHealth = false }

        guard await coordinator.syncChanges() else {
            refreshError = L10n.text("viewer.refresh.failed")
            return
        }
        await loadSnapshot(showLoading: false)
    }

    private func loadSnapshot(showLoading: Bool = true) async {
        if showLoading { state = .loading }
        do {
            state = .loaded(try await coordinator.loadAgentSnapshotForViewer())
        } catch let error as CloudExportStoreError {
            switch error {
            case .agentSnapshotMissing:
                if showLoading { state = .unavailable }
            case .wouldReplacePopulatedSnapshotWithEmpty:
                if showLoading {
                    state = .failed(error.localizedDescription)
                } else {
                    refreshError = error.localizedDescription
                }
            }
        } catch {
            if showLoading {
                state = .failed(error.localizedDescription)
            } else {
                refreshError = error.localizedDescription
            }
        }
    }
}

private enum SnapshotViewState {
    case loading
    case loaded(HealthDataSnapshot)
    case unavailable
    case failed(String)
}

private struct ViewerMetricItem: Identifiable {
    let key: String
    let metric: SnapshotMetric
    var id: String { key }
}

private struct ViewerCategoryItem: Identifiable {
    let key: String
    let category: SnapshotCategory
    var id: String { key }
}

private struct ViewerSpecialItem: Identifiable {
    let key: String
    let records: [SnapshotSpecialRecord]
    var id: String { key }
}

private struct ViewerMetricGroup: Identifiable {
    let id: String
    let symbol: String
    let color: Color
    let items: [ViewerMetricItem]
}

private struct ViewerSectionCard<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .viewerCard(padding: 18)
    }
}

private struct ViewerNavigationCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .viewerCard()
    }
}

private struct ViewerSimpleRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct MetricSummaryRow: View {
    let metric: SnapshotMetric
    let key: String
    let period: HealthDataPeriod

    var body: some View {
        let presentation = ViewerPresentation.metric(key)
        HStack(spacing: 12) {
            Image(systemName: presentation.symbol)
                .foregroundStyle(presentation.color)
                .frame(width: 32, height: 32)
                .background(presentation.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(metric.aggregation == "dailySum" ? L10n.text("viewer.metric.total") : L10n.text("viewer.metric.latest"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(summary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var summary: String {
        let points = metric.daily.compactMap { SnapshotMetricPoint(row: $0, aggregation: metric.aggregation) }
            .filter { period.includes($0.parsedDate) }
        guard !points.isEmpty else { return L10n.text("viewer.empty.value") }
        if metric.aggregation == "dailySum" {
            return ViewerFormat.value(points.compactMap(\.sum).reduce(0, +), unit: metric.unit)
        }
        let latest = points.sorted { $0.date < $1.date }.last
        return ViewerFormat.value(latest?.latest ?? latest?.average, unit: metric.unit)
    }
}

private struct CategorySummaryRow: View {
    let category: SnapshotCategory
    let key: String
    let period: HealthDataPeriod

    var body: some View {
        let presentation = ViewerPresentation.category(key)
        let count = category.daily
            .flatMap(SnapshotCategoryPoint.points(row:))
            .filter { period.includes($0.parsedDate) }
            .reduce(0) { $0 + ($1.count ?? 1) }
        ViewerSimpleRow(
            title: presentation.title,
            subtitle: count == 0 ? L10n.text("viewer.empty.period") : L10n.format("viewer.event.count", count),
            symbol: presentation.symbol,
            color: presentation.color
        )
    }
}

private struct MetricDetailView: View {
    let metric: SnapshotMetric
    let key: String
    let period: HealthDataPeriod

    private var points: [SnapshotMetricPoint] {
        metric.daily.compactMap { SnapshotMetricPoint(row: $0, aggregation: metric.aggregation) }
            .filter { period.includes($0.parsedDate) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section {
                Text(metric.aggregation == "dailySum" ? L10n.text("viewer.metric.sum.caption") : L10n.text("viewer.metric.range.caption"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if points.isEmpty {
                ContentUnavailableView(
                    L10n.text("viewer.empty.period"),
                    systemImage: "calendar.badge.exclamationmark"
                )
            } else {
                ForEach(points) { point in
                    MetricPointRow(point: point, unit: metric.unit, isCumulative: metric.aggregation == "dailySum")
                }
            }
        }
        .navigationTitle(ViewerPresentation.metric(key).title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MetricPointRow: View {
    let point: SnapshotMetricPoint
    let unit: String
    let isCumulative: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ViewerFormat.day(point.parsedDate, fallback: point.date))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(isCumulative
                    ? ViewerFormat.value(point.sum, unit: unit)
                    : ViewerFormat.value(point.latest ?? point.average, unit: unit)
                )
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            }
            if !isCumulative {
                HStack(spacing: 10) {
                    ViewerMiniValue(title: L10n.text("viewer.metric.average"), value: ViewerFormat.value(point.average, unit: unit))
                    ViewerMiniValue(title: L10n.text("viewer.metric.minimum"), value: ViewerFormat.value(point.minimum, unit: unit))
                    ViewerMiniValue(title: L10n.text("viewer.metric.maximum"), value: ViewerFormat.value(point.maximum, unit: unit))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ViewerMiniValue: View {
    let title: String
    let value: String
    let symbol: String?
    let color: Color

    init(title: String, value: String, symbol: String? = nil, color: Color = .secondary) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let symbol {
                Label(title, systemImage: symbol)
                    .font(.caption2)
                    .foregroundStyle(color)
                    .lineLimit(1)
            } else {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CategoryDetailView: View {
    let category: SnapshotCategory
    let key: String
    let period: HealthDataPeriod

    private var points: [SnapshotCategoryPoint] {
        category.daily.flatMap(SnapshotCategoryPoint.points(row:))
            .filter { period.includes($0.parsedDate) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            if points.isEmpty {
                ContentUnavailableView(L10n.text("viewer.empty.period"), systemImage: "calendar.badge.exclamationmark")
            } else {
                ForEach(points) { point in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ViewerFormat.day(point.parsedDate, fallback: point.date))
                                .font(.subheadline.weight(.semibold))
                            Text(ViewerPresentation.categoryValue(point.value))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            if let count = point.count {
                                Text(L10n.format("viewer.event.count", count))
                                    .font(.caption.weight(.semibold))
                            }
                            if let minutes = point.minutes, minutes > 0 {
                                Text(L10n.format("viewer.event.minutes", HealthNumberFormatter.string(minutes)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(ViewerPresentation.category(key).title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ActivityRingDetailView: View {
    let rings: [SnapshotActivityRing]
    let period: HealthDataPeriod

    private var filtered: [SnapshotActivityRing] {
        rings.filter { period.includes($0.parsedDate) }.sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(L10n.text("viewer.empty.period"), systemImage: "calendar.badge.exclamationmark")
            } else {
                ForEach(filtered) { ring in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ViewerFormat.day(ring.parsedDate, fallback: ring.date))
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 10) {
                            ViewerMiniValue(
                                title: L10n.text("viewer.activity.move"),
                                value: ViewerFormat.value(ring.activeEnergyKilocalories, unit: "kcal"),
                                symbol: "flame.fill",
                                color: .pink
                            )
                            ViewerMiniValue(
                                title: L10n.text("viewer.activity.exercise"),
                                value: ViewerFormat.value(ring.exerciseMinutes, unit: "min"),
                                symbol: "figure.run",
                                color: .mint
                            )
                            ViewerMiniValue(
                                title: L10n.text("viewer.activity.stand"),
                                value: ViewerFormat.value(ring.standHours, unit: "h"),
                                symbol: "figure.stand",
                                color: .cyan
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(L10n.text("viewer.section.activity"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SleepDetailView: View {
    let intervals: [SnapshotSleepInterval]
    let period: HealthDataPeriod

    private var filtered: [SnapshotSleepInterval] {
        intervals.filter { period.includes($0.startDate) }.sorted { $0.start > $1.start }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(L10n.text("viewer.empty.period"), systemImage: "calendar.badge.exclamationmark")
            } else {
                ForEach(filtered) { interval in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: ViewerPresentation.sleep(interval.value).symbol)
                            .foregroundStyle(.indigo)
                            .frame(width: 30, height: 30)
                            .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ViewerPresentation.sleep(interval.value).title)
                                .font(.subheadline.weight(.semibold))
                            Text(ViewerFormat.interval(start: interval.startDate, end: interval.endDate, fallback: interval.start))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text(ViewerFormat.duration(start: interval.startDate, end: interval.endDate))
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(L10n.text("viewer.section.sleep"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WorkoutDetailView: View {
    let workouts: [SnapshotWorkout]
    let period: HealthDataPeriod

    private var filtered: [SnapshotWorkout] {
        workouts.filter { period.includes($0.startDate) }.sorted { $0.start > $1.start }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(L10n.text("viewer.empty.period"), systemImage: "calendar.badge.exclamationmark")
            } else {
                ForEach(filtered) { workout in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(ViewerPresentation.workout(workout.activity).title, systemImage: ViewerPresentation.workout(workout.activity).symbol)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(ViewerFormat.duration(minutes: workout.durationMinutes))
                                .font(.caption.weight(.semibold))
                        }
                        Text(ViewerFormat.interval(start: workout.startDate, end: workout.endDate, fallback: workout.start))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(workout.statistics.keys.sorted(), id: \.self) { key in
                            if let statistic = workout.statistics[key] {
                                HStack {
                                    Text(ViewerPresentation.metric(key).title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(ViewerFormat.value(statistic.sum ?? statistic.average, unit: statistic.unit))
                                        .font(.caption.weight(.semibold))
                                        .multilineTextAlignment(.trailing)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(L10n.text("viewer.section.workouts"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpecialRecordDetailView: View {
    let records: [SnapshotSpecialRecord]
    let key: String
    let period: HealthDataPeriod

    private var filtered: [SnapshotSpecialRecord] {
        records.filter { period.includes($0.startDate) }.sorted { $0.start > $1.start }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(L10n.text("viewer.empty.period"), systemImage: "calendar.badge.exclamationmark")
            } else {
                ForEach(filtered) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ViewerFormat.interval(start: record.startDate, end: SnapshotDate.parseTimestamp(record.end), fallback: record.start))
                            .font(.subheadline.weight(.semibold))
                        ForEach(record.details.keys.sorted(), id: \.self) { property in
                            if let value = record.details[property] {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(ViewerPresentation.property(property))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Text(value.displayText)
                                        .font(.caption.weight(.semibold))
                                        .multilineTextAlignment(.trailing)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(ViewerPresentation.special(key).title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfileDetailView: View {
    let profile: [String: JSONValue]

    var body: some View {
        List {
            ForEach(profile.keys.sorted(), id: \.self) { property in
                if let value = profile[property] {
                    HStack(alignment: .top, spacing: 12) {
                        Label(ViewerPresentation.property(property), systemImage: ViewerPresentation.profileSymbol(property))
                            .font(.subheadline)
                            .lineLimit(2)
                        Spacer(minLength: 12)
                        Text(ViewerPresentation.profileValue(value, property: property))
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(L10n.text("viewer.section.profile"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ViewerPresentation {
    struct Item {
        let title: String
        let symbol: String
        let color: Color
        let group: String
    }

    static let metricGroupOrder = ["activity", "heart", "respiratory", "mobility", "body", "other"]

    static func metric(_ key: String) -> Item {
        let values: [String: Item] = [
            "stepCount": item("viewer.metric.stepCount", "figure.walk", .orange, "activity"),
            "distanceWalkingRunning": item("viewer.metric.distanceWalkingRunning", "figure.walk.motion", .orange, "activity"),
            "activeEnergyBurned": item("viewer.metric.activeEnergyBurned", "flame.fill", .pink, "activity"),
            "basalEnergyBurned": item("viewer.metric.basalEnergyBurned", "flame", .pink, "activity"),
            "appleExerciseTime": item("viewer.metric.appleExerciseTime", "figure.run", .mint, "activity"),
            "appleStandTime": item("viewer.metric.appleStandTime", "figure.stand", .mint, "activity"),
            "flightsClimbed": item("viewer.metric.flightsClimbed", "stairs", .orange, "activity"),
            "physicalEffort": item("viewer.metric.physicalEffort", "figure.strengthtraining.traditional", .orange, "activity"),
            "timeInDaylight": item("viewer.metric.timeInDaylight", "sun.max.fill", .yellow, "activity"),
            "heartRate": item("viewer.metric.heartRate", "heart.fill", .red, "heart"),
            "restingHeartRate": item("viewer.metric.restingHeartRate", "heart.circle.fill", .red, "heart"),
            "walkingHeartRateAverage": item("viewer.metric.walkingHeartRateAverage", "figure.walk.heart", .red, "heart"),
            "heartRateVariabilitySDNN": item("viewer.metric.heartRateVariabilitySDNN", "waveform.path.ecg", .red, "heart"),
            "oxygenSaturation": item("viewer.metric.oxygenSaturation", "lungs.fill", .cyan, "respiratory"),
            "respiratoryRate": item("viewer.metric.respiratoryRate", "wind", .cyan, "respiratory"),
            "appleSleepingWristTemperature": item("viewer.metric.appleSleepingWristTemperature", "thermometer.medium", .indigo, "body"),
            "environmentalAudioExposure": item("viewer.metric.environmentalAudioExposure", "ear.fill", .purple, "body"),
            "headphoneAudioExposure": item("viewer.metric.headphoneAudioExposure", "headphones", .purple, "body"),
            "environmentalSoundReduction": item("viewer.metric.environmentalSoundReduction", "speaker.wave.2.fill", .purple, "body"),
            "appleWalkingSteadiness": item("viewer.metric.appleWalkingSteadiness", "figure.walk.motion", .blue, "mobility"),
            "walkingAsymmetryPercentage": item("viewer.metric.walkingAsymmetryPercentage", "figure.walk", .blue, "mobility"),
            "walkingDoubleSupportPercentage": item("viewer.metric.walkingDoubleSupportPercentage", "figure.walk", .blue, "mobility"),
            "walkingSpeed": item("viewer.metric.walkingSpeed", "speedometer", .blue, "mobility"),
            "walkingStepLength": item("viewer.metric.walkingStepLength", "ruler", .blue, "mobility"),
            "sixMinuteWalkTestDistance": item("viewer.metric.sixMinuteWalkTestDistance", "timer", .blue, "mobility"),
            "stairAscentSpeed": item("viewer.metric.stairAscentSpeed", "arrow.up.right", .blue, "mobility"),
            "stairDescentSpeed": item("viewer.metric.stairDescentSpeed", "arrow.down.right", .blue, "mobility"),
            "vO2Max": item("viewer.metric.vO2Max", "lungs.fill", .cyan, "respiratory")
        ]
        return values[key] ?? item(nil, "cross.case.fill", .gray, "other", fallback: readableKey(key))
    }

    static func category(_ key: String) -> Item {
        let values: [String: Item] = [
            "sleepAnalysis": item("viewer.category.sleepAnalysis", "bed.double.fill", .indigo, "other"),
            "appleStandHour": item("viewer.category.appleStandHour", "figure.stand", .mint, "activity"),
            "audioExposureEvent": item("viewer.category.audioExposureEvent", "speaker.wave.3.fill", .purple, "body")
        ]
        return values[key] ?? item(nil, "checklist.checked", .orange, "other", fallback: readableKey(key))
    }

    static func special(_ key: String) -> Item {
        switch key {
        case "electrocardiogram": item("viewer.special.electrocardiogram", "waveform.path.ecg", .red, "heart")
        case "heartbeatSeries": item("viewer.special.heartbeatSeries", "waveform", .red, "heart")
        default: item(nil, "heart.text.clipboard.fill", .red, "other", fallback: readableKey(key))
        }
    }

    static func sleep(_ value: String) -> Item {
        switch value {
        case "inBed": item("viewer.sleep.inBed", "bed.double.fill", .indigo, "other")
        case "awake": item("viewer.sleep.awake", "eyes", .orange, "other")
        case "asleepCore": item("viewer.sleep.asleepCore", "moon.fill", .indigo, "other")
        case "asleepDeep": item("viewer.sleep.asleepDeep", "moon.stars.fill", .indigo, "other")
        case "asleepREM": item("viewer.sleep.asleepREM", "sparkles", .indigo, "other")
        case "asleepUnspecified": item("viewer.sleep.asleepUnspecified", "moon.fill", .indigo, "other")
        default: item(nil, "bed.double.fill", .indigo, "other", fallback: readableKey(value))
        }
    }

    static func workout(_ key: String) -> Item {
        let values: [String: Item] = [
            "walking": item("viewer.workout.walking", "figure.walk", .mint, "activity"),
            "running": item("viewer.workout.running", "figure.run", .mint, "activity"),
            "cycling": item("viewer.workout.cycling", "figure.outdoor.cycle", .mint, "activity"),
            "swimming": item("viewer.workout.swimming", "figure.pool.swim", .mint, "activity"),
            "hiking": item("viewer.workout.hiking", "figure.hiking", .mint, "activity"),
            "yoga": item("viewer.workout.yoga", "figure.yoga", .mint, "activity"),
            "traditionalStrengthTraining": item("viewer.workout.strength", "dumbbell.fill", .mint, "activity")
        ]
        return values[key] ?? item(nil, "figure.mixed.cardio", .mint, "activity", fallback: readableKey(key))
    }

    static func groupTitle(_ group: String) -> String {
        L10n.text("viewer.group.\(group)")
    }

    static func groupVisual(_ group: String) -> (symbol: String, color: Color) {
        switch group {
        case "activity": ("figure.run", .orange)
        case "heart": ("heart.fill", .red)
        case "respiratory": ("lungs.fill", .cyan)
        case "mobility": ("figure.walk.motion", .blue)
        case "body": ("cross.case.fill", .purple)
        default: ("square.grid.2x2.fill", .gray)
        }
    }

    static func periodTitle(_ period: HealthDataPeriod) -> String {
        L10n.text("viewer.period.\(period.rawValue)")
    }

    static func categoryValue(_ value: String) -> String {
        let localized = L10n.text("viewer.categoryValue.\(value)")
        return localized == "viewer.categoryValue.\(value)" ? readableKey(value) : localized
    }

    static func property(_ key: String) -> String {
        let localized = L10n.text("viewer.property.\(key)")
        return localized == "viewer.property.\(key)" ? readableKey(key) : localized
    }

    static func profileSymbol(_ property: String) -> String {
        switch property {
        case "dateOfBirth": "calendar"
        case "biologicalSex": "person.fill"
        case "bloodType": "drop.fill"
        case "wheelchairUse": "figure.roll"
        default: "person.text.rectangle"
        }
    }

    static func profileValue(_ value: JSONValue, property: String) -> String {
        if property == "dateOfBirth",
           let values = value.objectValue,
           let year = values["year"]?.integerValue,
           let month = values["month"]?.integerValue,
           let day = values["day"]?.integerValue {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            if let date = Calendar.autoupdatingCurrent.date(from: components) {
                return date.formatted(.dateTime.day().month(.wide).year().locale(.autoupdatingCurrent))
            }
        }

        let rawValue = value.stringValue ?? value.integerValue.map(String.init)
        if let rawValue {
            let key = "viewer.profileValue.\(property).\(rawValue)"
            let localized = L10n.text(key)
            if localized != key { return localized }
        }
        return value.displayText
    }

    static func countText(_ count: Int) -> String {
        count == 0 ? L10n.text("viewer.empty.period") : L10n.format("viewer.record.count", count)
    }

    private static func item(_ key: String?, _ symbol: String, _ color: Color, _ group: String, fallback: String? = nil) -> Item {
        Item(title: key.map(L10n.text) ?? fallback ?? "", symbol: symbol, color: color, group: group)
    }

    private static func readableKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "SDNN", with: "SDNN")
            .capitalized
    }
}

private enum ViewerFormat {
    static func value(_ value: Double?, unit: String) -> String {
        guard let value else { return L10n.text("viewer.value.not_available") }
        // HealthKit's percent unit stores one whole as 1.0. Keep the canonical
        // JSON untouched, but render 0.98 as the familiar 98 % in the UI.
        let displayValue = HealthDisplayValue.normalized(value, unit: unit)
        let formatted = HealthNumberFormatter.string(displayValue)
        let unit = displayUnit(unit)
        return unit.isEmpty ? formatted : "\(formatted) \(unit)"
    }

    static func day(_ date: Date?, fallback: String) -> String {
        guard let date else { return fallback }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.autoupdatingCurrent))
    }

    static func interval(start: Date?, end: Date?, fallback: String) -> String {
        guard let start else { return fallback }
        let startText = start.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(.autoupdatingCurrent))
        guard let end else { return startText }
        return "\(startText) — \(end.formatted(.dateTime.hour().minute().locale(.autoupdatingCurrent)))"
    }

    static func duration(start: Date?, end: Date?) -> String {
        guard let start, let end else { return L10n.text("viewer.value.not_available") }
        return duration(minutes: end.timeIntervalSince(start) / 60)
    }

    static func duration(minutes: Double?) -> String {
        guard let minutes else { return L10n.text("viewer.value.not_available") }
        let rounded = Int(minutes.rounded())
        let hours = rounded / 60
        let remainder = rounded % 60
        if hours > 0, remainder > 0 {
            return L10n.format("viewer.duration.hoursMinutes", hours, remainder)
        }
        if hours > 0 { return L10n.format("viewer.duration.hours", hours) }
        return L10n.format("viewer.duration.minutes", remainder)
    }

    private static func displayUnit(_ unit: String) -> String {
        switch unit {
        case "count": ""
        case "count/min": L10n.text("viewer.unit.bpm")
        case "Cal", "kcal": L10n.text("viewer.unit.kcal")
        case "min": L10n.text("viewer.unit.minutes")
        case "h": L10n.text("viewer.unit.hours")
        case "degC": "°C"
        case "degF": "°F"
        case "dBASPL": L10n.text("viewer.unit.decibel_a")
        case "Cal/hr·kg", "kcal/hr·kg": L10n.text("viewer.unit.kcal_per_hour_kg")
        case "%": "%"
        default: unit
        }
    }
}

private extension View {
    func viewerCard(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}
