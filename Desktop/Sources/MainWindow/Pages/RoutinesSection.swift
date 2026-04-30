import SwiftUI
import GRDB

/// Routines tab: scheduled AI tasks. Shows the list of routines on top with
/// per-row enable/disable controls, and a chronological timeline of recent
/// runs underneath. Users create routines by talking to the agent ("every
/// weekday at 9am check my emails"), so this view is mostly read-only — its
/// job is to make the existing routines and their results legible.
///
/// Data is read from `cron_jobs` + `cron_runs` tables (added in fazmV7).
/// The headless runner (`acp-bridge/src/cron-runner.mjs`) writes those tables
/// from launchd, and the Swift app reads them. WAL mode keeps both safe.
struct RoutinesSection: View {
    var chatProvider: ChatProvider? = nil

    @State private var jobs: [CronJob] = []
    @State private var runs: [CronRun] = []
    @State private var isLoading = true
    @State private var selectedJobId: String? = nil  // nil = "all"

    @State private var refreshTimer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    private var filteredRuns: [CronRun] {
        guard let jid = selectedJobId else { return runs }
        return runs.filter { $0.jobId == jid }
    }

    private var jobNamesById: [String: String] {
        Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.name) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)

            if isLoading {
                Spacer()
                HStack { Spacer(); ProgressView(); Spacer() }
                Spacer()
            } else if jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        routinesList
                        runsTimeline
                    }
                }
            }
        }
        .onAppear { loadAll() }
        .onReceive(refreshTimer) { _ in loadAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recurring AI tasks that run on a schedule.")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textSecondary)
                Text("Create one by asking Fazm: \"every weekday at 9am, check my email\".")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
            }
            Spacer()
            Button(action: openComposeWithPrompt) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").scaledFont(size: 13)
                    Text("New Routine")
                }
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(FazmColors.purplePrimary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Opens the floating bar with a prompt prefilled — describe the routine in natural language.")
        }
    }

    // MARK: - Routines list

    private var routinesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ROUTINES")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundColor(FazmColors.textTertiary)
                    .tracking(0.5)
                Spacer()
                if selectedJobId != nil {
                    Button("Show all") { selectedJobId = nil }
                        .buttonStyle(.plain)
                        .scaledFont(size: 11)
                        .foregroundColor(FazmColors.purplePrimary)
                }
            }

            VStack(spacing: 6) {
                ForEach(jobs) { job in
                    RoutineRow(
                        job: job,
                        isSelected: selectedJobId == job.id,
                        onTap: { selectedJobId = (selectedJobId == job.id ? nil : job.id) },
                        onToggle: { newValue in toggleEnabled(job: job, enabled: newValue) }
                    )
                }
            }
        }
    }

    // MARK: - Runs timeline

    private var runsTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selectedJobId == nil ? "RECENT RUNS" : "RUNS · \(jobNamesById[selectedJobId!] ?? "")")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundColor(FazmColors.textTertiary)
                    .tracking(0.5)
                Spacer()
                Text("\(filteredRuns.count)")
                    .scaledFont(size: 11)
                    .foregroundColor(FazmColors.textQuaternary)
            }

            if filteredRuns.isEmpty {
                Text("No runs yet. They'll appear here once a routine fires.")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 6) {
                    ForEach(filteredRuns) { run in
                        RunRow(run: run, jobName: jobNamesById[run.jobId] ?? "Unknown routine")
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "clock.badge.checkmark")
                .scaledFont(size: 36)
                .foregroundColor(FazmColors.textQuaternary)
            VStack(spacing: 6) {
                Text("No routines yet")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundColor(FazmColors.textSecondary)
                Text("Ask Fazm to set one up: \"every weekday at 9am, summarize my unread emails\".")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private func loadAll() {
        Task {
            let loadedJobs = await CronJobStore.listJobs()
            let loadedRuns = await CronJobStore.listRuns(jobId: nil, limit: 80)
            await MainActor.run {
                if loadedJobs != jobs { jobs = loadedJobs }
                if loadedRuns != runs { runs = loadedRuns }
                if isLoading { isLoading = false }
            }
        }
    }

    private func toggleEnabled(job: CronJob, enabled: Bool) {
        Task {
            await CronJobStore.setEnabled(id: job.id, enabled: enabled)
            loadAll()
        }
    }

    private func openComposeWithPrompt() {
        // Open the floating bar prefilled with a routine-creation prompt so
        // the user just has to describe their routine in plain English.
        let preset = "Create a routine that "
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.fazm.testQuery"),
            object: nil,
            userInfo: ["text": preset, "openBar": "true"],
            deliverImmediately: true
        )
    }
}

// MARK: - Routine row

private struct RoutineRow: View {
    let job: CronJob
    let isSelected: Bool
    let onTap: () -> Void
    let onToggle: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusDot

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(FazmColors.textPrimary)
                    .lineLimit(1)
                Text(humanSchedule(job.schedule) + nextRunSuffix(job.nextRunAt))
                    .scaledFont(size: 11)
                    .foregroundColor(FazmColors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if let lastErr = job.lastError, job.lastStatus == "error" {
                Text(lastErr.prefix(48) + (lastErr.count > 48 ? "…" : ""))
                    .scaledFont(size: 10)
                    .foregroundColor(.red.opacity(0.85))
                    .lineLimit(1)
            }

            Toggle("", isOn: Binding(get: { job.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? FazmColors.purplePrimary.opacity(0.12)
                      : (isHovered ? FazmColors.backgroundTertiary.opacity(0.7) : FazmColors.backgroundTertiary.opacity(0.4)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? FazmColors.purplePrimary.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovered = $0 }
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    private var dotColor: Color {
        if !job.enabled { return FazmColors.textQuaternary }
        switch job.lastStatus {
        case "ok": return .green
        case "error", "timeout": return .red
        case "running": return .orange
        default: return FazmColors.purplePrimary
        }
    }

    private func nextRunSuffix(_ next: Date?) -> String {
        guard let next = next, job.enabled else { return "" }
        if next < Date() { return "  ·  due now" }
        return "  ·  next " + relativeTimeString(next)
    }
}

// MARK: - Run row

private struct RunRow: View {
    let run: CronRun
    let jobName: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusBadge
                Text(jobName)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(FazmColors.textSecondary)
                Spacer()
                Text(run.startedAt, style: .relative)
                    .scaledFont(size: 11)
                    .foregroundColor(FazmColors.textTertiary)
                if let cost = run.costUsd, cost > 0 {
                    Text(String(format: "$%.4f", cost))
                        .scaledFont(size: 10)
                        .foregroundColor(FazmColors.textQuaternary)
                }
            }

            if let preview = previewText, !preview.isEmpty {
                Text(isExpanded ? preview : truncated(preview, 240))
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textPrimary.opacity(0.85))
                    .lineLimit(isExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)

                if preview.count > 240 {
                    Button(isExpanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .scaledFont(size: 11)
                    .foregroundColor(FazmColors.purplePrimary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(FazmColors.backgroundTertiary.opacity(0.4))
        )
    }

    private var previewText: String? {
        if run.status == "error" || run.status == "timeout" {
            return run.errorMessage ?? run.outputText
        }
        return run.outputText
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch run.status {
            case "ok": return ("✓", .green)
            case "error": return ("!", .red)
            case "timeout": return ("⏱", .orange)
            case "running": return ("…", .blue)
            default: return ("?", FazmColors.textQuaternary)
            }
        }()
        return Text(label)
            .scaledFont(size: 10, weight: .bold)
            .foregroundColor(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color))
    }

    private func truncated(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }
}

// MARK: - Helpers

/// Human-readable label for a schedule string.
/// Best-effort — produces useful output for common shapes ("0 9 * * *",
/// "every:1800", "at:..."), and falls back to the raw string otherwise.
func humanSchedule(_ schedule: String) -> String {
    guard let colon = schedule.firstIndex(of: ":") else { return schedule }
    let kind = String(schedule[..<colon])
    let rest = String(schedule[schedule.index(after: colon)...])

    switch kind {
    case "every":
        if let sec = Int(rest) {
            if sec % 3600 == 0 { return "Every \(sec / 3600) hour\(sec / 3600 == 1 ? "" : "s")" }
            if sec % 60 == 0 { return "Every \(sec / 60) minutes" }
            return "Every \(sec) seconds"
        }
        return "Every \(rest)"
    case "at":
        if let date = ISO8601DateFormatter().date(from: rest) {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return "Once on " + f.string(from: date)
        }
        return "Once at \(rest)"
    case "cron":
        return cronToHuman(rest)
    default:
        return schedule
    }
}

private func cronToHuman(_ expr: String) -> String {
    let parts = expr.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count == 5 else { return "cron:\(expr)" }
    let (min, hour, dom, mon, dow) = (parts[0], parts[1], parts[2], parts[3], parts[4])

    // Time portion
    let time: String? = {
        if let h = Int(hour), let m = Int(min) {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            var c = DateComponents()
            c.hour = h; c.minute = m
            if let d = Calendar.current.date(from: c) { return f.string(from: d) }
        }
        if hour == "*" && min.contains("/") { return "every \(min.dropFirst(2)) min" }
        return nil
    }()

    // Days portion
    let days: String = {
        if dow == "*" && dom == "*" { return "Daily" }
        if dom == "*" {
            switch dow {
            case "1-5": return "Weekdays"
            case "0,6", "6,0": return "Weekends"
            case "1": return "Mondays"
            case "2": return "Tuesdays"
            case "3": return "Wednesdays"
            case "4": return "Thursdays"
            case "5": return "Fridays"
            case "6": return "Saturdays"
            case "0", "7": return "Sundays"
            default: return "On days \(dow)"
            }
        }
        return "cron:\(expr)"
    }()

    if let time = time {
        return "\(days) at \(time)"
    }
    return days
}

private func relativeTimeString(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}
