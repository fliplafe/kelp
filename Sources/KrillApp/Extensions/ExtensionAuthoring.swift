import AppKit
import Core

/// Making extensions: an empty one to edit by hand, or an agent that builds it from a description.
@MainActor
enum ExtensionAuthoring {
    static func create() {
        guard let name = prompt("New Extension", "Name (e.g. “Docker”, “Simulators”):"), !name.isEmpty else { return }
        guard let dir = scaffold(name: name, description: "") else { return }
        ExtensionRegistry.shared.reload()
        Workbench.open(TabURI.file(dir.appendingPathComponent("extension.json").path))
    }

    /// Describe what you want; an agent writes the extension next to the authoring guide while Krill reloads it live.
    static func createWithAI() {
        guard let what = prompt("Create an Extension with AI", "What should it show or do? e.g. “Docker containers with logs and shell”, “iOS simulators I can boot”."),
              !what.isEmpty else { return }
        guard let dir = scaffold(name: String(what.prefix(40)), description: what) else { return }
        startAgent(in: dir, prompt: """
        Build a Krill IDE extension in this folder: \(what)
        Read ../EXTENSIONS.md first — it is the complete format. Edit extension.json (and add files such as an HTML page if needed) in this folder only.
        Krill reloads the extension every time you save. Check it with `krill ext list` (load errors show there) and test list commands in the shell first — they must print JSON.
        When it works, say where it appears in Krill and how to use it.
        """)
    }

    static func improve(_ e: ExtensionInfo) {
        guard let dir = e.path, let what = prompt("Improve “\(e.name)”", "What should change?"), !what.isEmpty else { return }
        startAgent(in: dir, prompt: "Change this Krill extension (\(e.name)): \(what)\nThe format is in ../EXTENSIONS.md. Krill reloads it when you save; check with `krill ext list`.")
    }

    private static func scaffold(name: String, description: String) -> URL? {
        var id = name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        if id.isEmpty || !IDE.isValidExtensionID(id) { id = "extension-\(Int(Date().timeIntervalSince1970) % 100000)" }
        var unique = id, n = 2
        while FileManager.default.fileExists(atPath: ExtensionRegistry.userDir.appendingPathComponent(unique).path) { unique = "\(id)-\(n)"; n += 1 }
        do { return try IDE.scaffoldExtension(id: unique, name: name, description: description, in: ExtensionRegistry.userDir) }
        catch { Banner.show("Couldn't create the extension: \(error.localizedDescription)", style: .error); return nil }
    }

    private static func startAgent(in dir: URL, prompt: String) {
        var p: [String: JSONValue] = ["cwd": .string(dir.path), "agent": .string(AgentCatalog.defaultAgent), "prompt": .string(prompt), "title": "Extension builder"]
        if let w = Workbench.shared.workspaceId { p["worktreeId"] = .string(w) }
        Task {
            guard let r = await AppModel.shared.call("session.create", .object(p)), let s = try? r.decode(Session.self) else { return }
            AppModel.shared.upsert(s)
            Workbench.open(TabURI.session(s.id), split: .right)
            Workbench.open(TabURI.file(dir.appendingPathComponent("extension.json").path))
        }
    }
}
