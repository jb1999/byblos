import Foundation

// MARK: - Skill Model

struct Skill: Identifiable, Sendable {
    let id: String          // directory name
    let name: String
    let trigger: String     // pipe-separated keywords
    let description: String
    let instructions: String // full SKILL.md content for LLM context
}

// MARK: - SkillsManager

@MainActor
class SkillsManager: ObservableObject {
    static let shared = SkillsManager()

    @Published var skills: [Skill] = []

    var skillsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Byblos/skills")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Loading

    func loadSkills() {
        let fm = FileManager.default
        let baseDir = skillsDirectoryURL

        guard let contents = try? fm.contentsOfDirectory(atPath: baseDir.path) else {
            Log.info("[Skills] No skills directory or empty")
            return
        }

        var loaded: [Skill] = []
        for dirName in contents {
            let skillDir = baseDir.appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: skillDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let skillFile = skillDir.appendingPathComponent("SKILL.md")
            guard let raw = try? String(contentsOf: skillFile, encoding: .utf8) else {
                continue
            }

            if let skill = parseSkillMd(raw, id: dirName) {
                loaded.append(skill)
            }
        }

        skills = loaded
        Log.info("[Skills] Loaded \(skills.count) skills")
    }

    // MARK: - Matching

    /// Match user input to a skill by checking trigger keywords.
    func matchSkill(for input: String) -> Skill? {
        let lower = input.lowercased()
        for skill in skills {
            let triggers = skill.trigger
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            for trigger in triggers {
                if lower.contains(trigger) {
                    Log.info("[Skills] Matched skill '\(skill.name)' for input")
                    return skill
                }
            }
        }
        return nil
    }

    // MARK: - Install / Remove / Create

    func installSkill(from url: URL) {
        let fm = FileManager.default
        let destName = url.lastPathComponent
        let dest = skillsDirectoryURL.appendingPathComponent(destName)

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
            loadSkills()
            Log.info("[Skills] Installed skill from \(url.lastPathComponent)")
        } catch {
            Log.error("[Skills] Install failed: \(error)")
        }
    }

    func removeSkill(id: String) {
        let dir = skillsDirectoryURL.appendingPathComponent(id)
        do {
            try FileManager.default.removeItem(at: dir)
            skills.removeAll { $0.id == id }
            Log.info("[Skills] Removed skill: \(id)")
        } catch {
            Log.error("[Skills] Remove failed: \(error)")
        }
    }

    func createSkill(name: String, trigger: String, description: String = "", instructions: String) {
        let dirName = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        let dir = skillsDirectoryURL.appendingPathComponent(dirName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let desc = description.isEmpty ? name : description
        let content = """
        ---
        name: \(name)
        trigger: "\(trigger)"
        description: \(desc)
        ---

        ## Instructions
        \(instructions)
        """

        let file = dir.appendingPathComponent("SKILL.md")
        do {
            try content.write(to: file, atomically: true, encoding: .utf8)
            loadSkills()
            Log.info("[Skills] Created skill: \(name)")
        } catch {
            Log.error("[Skills] Create failed: \(error)")
        }
    }

    // MARK: - SKILL.md Parser

    private func parseSkillMd(_ raw: String, id: String) -> Skill? {
        // Parse YAML front matter between --- delimiters.
        let parts = raw.components(separatedBy: "---")
        guard parts.count >= 3 else {
            // No front matter — use directory name as fallback.
            return Skill(id: id, name: id, trigger: id, description: "", instructions: raw)
        }

        let frontMatter = parts[1]
        let body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)

        var name = id
        var trigger = id
        var description = ""

        for line in frontMatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("trigger:") {
                trigger = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("description:") {
                description = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            }
        }

        return Skill(id: id, name: name, trigger: trigger, description: description, instructions: body)
    }
}
