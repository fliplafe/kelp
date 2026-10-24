import Foundation

/// CI runs of one branch, the same for GitHub Actions (`gh run`) and GitLab pipelines (`glab api`).
public enum CIRuns {
    /// Finished without success (failed, timed out, cancelled…).
    public static func failed(_ status: String, _ conclusion: String?) -> Bool {
        status == "completed" && !["success", "skipped", "neutral", nil].contains(conclusion)
    }
    public struct Step: Codable, Sendable, Equatable {
        public var name: String; public var status: String; public var conclusion: String?
        public init(name: String, status: String, conclusion: String?) { self.name = name; self.status = status; self.conclusion = conclusion }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    public struct Job: Codable, Sendable, Equatable {
        public var id: Int, name: String, status: String, conclusion: String?, url: String?
        public var steps: [Step]
        public init(id: Int, name: String, status: String, conclusion: String?, url: String?, steps: [Step]) {
            self.id = id; self.name = name; self.status = status; self.conclusion = conclusion; self.url = url; self.steps = steps
        }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    public struct Run: Codable, Sendable, Equatable {
        public var id: Int, title: String, workflow: String, status: String, conclusion: String?, event: String, url: String, createdAt: String
        public init(id: Int, title: String, workflow: String, status: String, conclusion: String?, event: String, url: String, createdAt: String) {
            self.id = id; self.title = title; self.workflow = workflow; self.status = status; self.conclusion = conclusion
            self.event = event; self.url = url; self.createdAt = createdAt
        }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    /// The newest run of each workflow (runs come newest first): what the branch's CI says now.
    public static func latest(_ runs: [Run]) -> [Run] {
        var seen = Set<String>()
        return runs.filter { seen.insert($0.workflow).inserted }
    }
    /// A workflow you can start by hand (`on: workflow_dispatch`), with the inputs its form asks for.
    public struct Workflow: Codable, Sendable, Equatable {
        public struct Input: Codable, Sendable, Equatable {
            public var name: String, description: String, defaultValue: String, options: [String], required: Bool
            public init(name: String, description: String, defaultValue: String, options: [String], required: Bool) {
                self.name = name; self.description = description; self.defaultValue = defaultValue; self.options = options; self.required = required
            }
        }
        public var file: String, name: String, inputs: [Input]
        public init(file: String, name: String, inputs: [Input]) { self.file = file; self.name = name; self.inputs = inputs }
    }
}
