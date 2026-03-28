import Foundation

// MARK: - Models

struct ScheduledTask: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var prompt: String
    var schedule: TaskSchedule
    var enabled: Bool
    var lastRun: Date?
    var lastResult: String?
}

enum TaskSchedule: Codable, Sendable {
    case daily(hour: Int, minute: Int)
    case weekdays(hour: Int, minute: Int)
    case interval(minutes: Int)
    case manual
}

// MARK: - TaskScheduler

@MainActor
class TaskScheduler: ObservableObject {
    static let shared = TaskScheduler()

    @Published var tasks: [ScheduledTask] = []
    private var timer: Timer?

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Byblos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scheduled-tasks.json")
    }

    // MARK: - Lifecycle

    func start() {
        load()
        ensureDailyBriefing()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        Log.info("[TaskScheduler] Started with \(tasks.count) tasks")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Log.info("[TaskScheduler] Stopped")
    }

    // MARK: - CRUD

    func addTask(_ task: ScheduledTask) {
        tasks.append(task)
        save()
        Log.info("[TaskScheduler] Added task: \(task.name)")
    }

    func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
        Log.info("[TaskScheduler] Removed task: \(id)")
    }

    func updateTask(_ task: ScheduledTask) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
            save()
        }
    }

    // MARK: - Execution

    func runTask(_ task: ScheduledTask) async -> String {
        Log.info("[TaskScheduler] Running task: \(task.name)")

        let result = await AgentEngine.shared.process(task.prompt)

        // Update last run.
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].lastRun = Date()
            tasks[idx].lastResult = result
            save()
        }

        // Show notification.
        _ = ScriptRunner.showNotification(title: "Byblos: \(task.name)", message: String(result.prefix(200)))

        // Save to transcripts.
        let entry = TranscriptEntry(
            text: "[\(task.name)] \(result)",
            rawText: task.prompt,
            mode: "agent",
            duration: 0,
            language: "en",
            appContext: nil
        )
        TranscriptStore.shared.addEntry(entry)

        Log.info("[TaskScheduler] Task '\(task.name)' completed")
        return result
    }

    // MARK: - Timer Tick

    private func tick() {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let weekday = calendar.component(.weekday, from: now) // 1=Sun, 7=Sat

        for task in tasks where task.enabled {
            guard isDue(task: task, hour: hour, minute: minute, weekday: weekday, now: now) else {
                continue
            }

            Task {
                _ = await runTask(task)
            }
        }
    }

    private func isDue(task: ScheduledTask, hour: Int, minute: Int, weekday: Int, now: Date) -> Bool {
        // Skip if ran within the last 2 minutes (prevent double-fire).
        if let lastRun = task.lastRun, now.timeIntervalSince(lastRun) < 120 {
            return false
        }

        switch task.schedule {
        case .daily(let h, let m):
            return hour == h && minute == m

        case .weekdays(let h, let m):
            let isWeekday = weekday >= 2 && weekday <= 6
            return isWeekday && hour == h && minute == m

        case .interval(let minutes):
            guard let lastRun = task.lastRun else { return true }
            return now.timeIntervalSince(lastRun) >= Double(minutes) * 60.0

        case .manual:
            return false
        }
    }

    // MARK: - Daily Briefing

    private func ensureDailyBriefing() {
        let briefingId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        guard !tasks.contains(where: { $0.id == briefingId }) else { return }

        let briefing = ScheduledTask(
            id: briefingId,
            name: "Daily Briefing",
            prompt: "Give me a brief morning summary: what day is it, what's on my calendar today, and any reminders due today. Use AppleScript to read Calendar.app and Reminders.app for real data.",
            schedule: .weekdays(hour: 9, minute: 0),
            enabled: false,
            lastRun: nil,
            lastResult: nil
        )
        tasks.insert(briefing, at: 0)
        save()
        Log.info("[TaskScheduler] Added default Daily Briefing task")
    }

    // MARK: - Persistence

    func save() {
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Log.error("[TaskScheduler] Save failed: \(error)")
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            tasks = try JSONDecoder().decode([ScheduledTask].self, from: data)
            Log.info("[TaskScheduler] Loaded \(tasks.count) tasks")
        } catch {
            Log.error("[TaskScheduler] Load failed: \(error)")
        }
    }
}
