import Foundation

struct AgentProgram: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let name: String
    let summary: String
    let script: String
    var directory: String
    var createdAt = Date()

    static func valid(name: String, summary: String, script: String) -> Bool {
        func line(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.utf8.count <= limit
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        return line(name, limit: 100) && line(summary, limit: 600)
            && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && script.utf8.count <= 24_000
            && !script.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }
}

struct AgentProgramProposal: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case save, run }
    var action: Action
    var name: String?
    var summary: String?
    var script: String?
    var id: UUID?
    var arguments: [String]?
    var status: AgentCommandProposal.Status = .pending

    static let openingTag = "<SORA_PROGRAM>"
    static func match(_ text: String) -> (proposal: Self, prose: String)? {
        guard let span = AgentEnvelope.span(in: text, opening: openingTag, closing: "</SORA_PROGRAM>"),
              let data = span.json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard ProgramArguments.isValid(payload.arguments ?? []) else { return nil }
        switch payload.action {
        case .save:
            guard let name = payload.name, let summary = payload.summary, let script = payload.script,
                  AgentProgram.valid(name: name, summary: summary, script: script), payload.id == nil else { return nil }
        case .run:
            guard payload.id != nil, payload.script == nil else { return nil }
        }
        return (Self(action: payload.action, name: payload.name, summary: payload.summary, script: payload.script, id: payload.id, arguments: payload.arguments), span.prose)
    }

    private struct Payload: Decodable {
        let action: Action
        let name: String?
        let summary: String?
        let script: String?
        let id: UUID?
        let arguments: [String]?
    }
}

/// One atomic catalog is the source of truth; executable snapshots are regenerated
/// from its reviewed contents at run time. No provider history or credentials are stored.
struct AgentProgramStore {
    let directory: URL
    static var standard: Self {
        Self(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sora/Programs", isDirectory: true))
    }
    private var catalog: URL { directory.appendingPathComponent("catalog.json") }

    private var backup: URL { directory.appendingPathComponent("catalog.backup.json") }

    func load() throws -> [AgentProgram] {
        guard FileManager.default.fileExists(atPath: catalog.path) else {
            if FileManager.default.fileExists(atPath: backup.path) { throw ProgramError.invalidCatalog }
            return []
        }
        let data = try Data(contentsOf: catalog)
        let programs = try decode(data)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try data.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        return programs
    }

    private func decode(_ data: Data) throws -> [AgentProgram] {
        guard data.count <= 2_000_000 else { throw ProgramError.invalidCatalog }
        let programs = try JSONDecoder().decode([AgentProgram].self, from: data)
        guard programs.count <= 50, Set(programs.map(\.id)).count == programs.count,
              programs.allSatisfy({ AgentProgram.valid(name: $0.name, summary: $0.summary, script: $0.script) && $0.directory.hasPrefix("/") })
        else { throw ProgramError.invalidCatalog }
        return programs
    }

    func save(_ programs: [AgentProgram]) throws {
        guard programs.count <= 50 else { throw ProgramError.catalogFull }
        try prepareDirectory()
        let data = try JSONEncoder().encode(programs)
        _ = try decode(data)
        if FileManager.default.fileExists(atPath: catalog.path) {
            let previous = try Data(contentsOf: catalog)
            _ = try decode(previous)
            try previous.write(to: backup, options: .atomic)
        } else {
            try data.write(to: backup, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        try data.write(to: catalog, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalog.path)
    }

    func restoreBackup() throws -> [AgentProgram] {
        let data = try Data(contentsOf: backup)
        let programs = try decode(data)
        if FileManager.default.fileExists(atPath: catalog.path) {
            let preserved = directory.appendingPathComponent("catalog-before-restore-" + UUID().uuidString + ".json")
            try FileManager.default.copyItem(at: catalog, to: preserved)
        }
        try data.write(to: catalog, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalog.path)
        return programs
    }

    func command(for program: AgentProgram, arguments: [String] = []) throws -> String {
        guard ProgramArguments.isValid(arguments) else { throw ProgramError.invalidArguments }
        var isDirectory: ObjCBool = false
        guard program.directory.hasPrefix("/"), FileManager.default.fileExists(atPath: program.directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw ProgramError.missingDirectory }
        try prepareDirectory()
        let file = directory.appendingPathComponent(program.id.uuidString + ".sh")
        try Data(program.script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (["/bin/zsh -f", Self.quote(file.path)] + arguments.map(Self.quote)).joined(separator: " ")
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    enum ProgramError: LocalizedError {
        case invalidCatalog, catalogFull, missingDirectory, invalidArguments
        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "Use up to 32 arguments, totaling at most 3000 bytes, without control characters."
            case .invalidCatalog: return "The Programs catalog is damaged or contains invalid entries. Your saved file has not been overwritten."
            case .catalogFull: return "The catalog holds up to 50 programs. Remove a program before saving another."
            case .missingDirectory: return "The program is safely saved, but its working folder is unavailable. Choose another working folder before running it."
            }
        }
    }
}


/// Each line is one literal argument. Never evaluate or split shell syntax.
enum ProgramArguments {
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    static func isValid(_ arguments: [String]) -> Bool {
        arguments.count <= 32 && arguments.reduce(0, { $0 + $1.utf8.count }) <= 3000
            && arguments.allSatisfy { value in
                !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
    }
}

/// Plain-text handles survive draft edits and are resolved locally before sending.
enum ProgramMention {
    static func handle(_ program: AgentProgram, in programs: [AgentProgram]) -> String {
        func slug(_ name: String) -> String {
            let parts = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            return parts.filter { !$0.isEmpty }.joined(separator: "-")
        }
        let base = slug(program.name).isEmpty ? "program" : slug(program.name)
        let duplicates = programs.filter { (slug($0.name).isEmpty ? "program" : slug($0.name)) == base }
        return duplicates.count > 1 ? base + "-" + program.id.uuidString.lowercased() : base
    }

    static func query(in text: String) -> String? {
        guard let last = text.split(whereSeparator: { $0.isWhitespace }).last,
              text.last?.isWhitespace == false, last.first == "@",
              !last.dropFirst().contains("@") else { return nil }
        return String(last.dropFirst()).lowercased()
    }

    static func inserting(_ program: AgentProgram, into text: String, programs: [AgentProgram]) -> String {
        guard let query = query(in: text) else { return text }
        return String(text.dropLast(query.count + 1)) + "@" + handle(program, in: programs) + " "
    }

    static func resolve(_ text: String, programs: [AgentProgram]) -> [AgentProgram] {
        let tokens = Set(text.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() })
        return programs.filter { tokens.contains("@" + handle($0, in: programs)) }
    }
}
