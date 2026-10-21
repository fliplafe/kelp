import AppKit
import SwiftUI
import Core

struct IntegrationsSettings: View {
    @State private var key = ""
    @State private var linearStatus = String(localized: "Checking…")
    @State private var ghStatus = String(localized: "Checking…")
    @State private var ghFix: String?
    @State private var jiraStatus = String(localized: "Checking…")
    @State private var jiraSite = ""
    @State private var jiraEmail = ""
    @State private var jiraToken = ""
    @State private var bbStatus = ""
    @State private var bbUser = ""
    @State private var bbToken = ""
    var body: some View {
        Form {
            Section("GitHub") {
                HStack {
                    Text(ghStatus).foregroundStyle(.secondary)
                    Spacer()
                    if let cmd = ghFix { Button("Copy “\(cmd)”") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) } }
                }
                Text("Kelp uses the GitHub CLI and its login. Project boards need `gh auth refresh -s read:project`.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Jira") {
                Text(jiraStatus).foregroundStyle(.secondary)
                TextField("Site", text: $jiraSite, prompt: Text("acme.atlassian.net"))
                TextField("Email", text: $jiraEmail)
                SecureField("API token", text: $jiraToken)
                HStack {
                    Button("Connect") { Task {
                        if let r = await AppModel.shared.call("jira.setCredentials", .obj(["site": .string(jiraSite), "email": .string(jiraEmail), "token": .string(jiraToken)])) {
                            jiraStatus = String(localized: "Connected as \(r["name"]?.string ?? "")"); jiraToken = ""
                        }
                    } }.disabled(jiraSite.isEmpty || jiraEmail.isEmpty || jiraToken.isEmpty)
                    Button("Disconnect") { Task {
                        if await AppModel.shared.call("jira.setCredentials", .obj(["site": "", "email": "", "token": ""])) != nil {
                            jiraStatus = String(localized: "Not connected")
                        }
                    } }
                }
                Text("API token from id.atlassian.com › Security. Stored in your login keychain.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Bitbucket") {
                Text(bbStatus).foregroundStyle(.secondary)
                TextField("Username or email", text: $bbUser)
                SecureField("API token / app password", text: $bbToken)
                Button("Save") { Task {
                    if await AppModel.shared.call("bitbucket.setCredentials", .obj(["user": .string(bbUser), "token": .string(bbToken)])) != nil {
                        bbStatus = String(localized: "Saved"); bbToken = ""
                    }
                } }
                    .disabled(bbUser.isEmpty || bbToken.isEmpty)
                Text("Used for pull requests in repos whose origin is on bitbucket.org.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Linear") {
                Text(linearStatus).foregroundStyle(.secondary)
                SecureField("Personal API key", text: $key)
                HStack {
                    Button("Connect") { Task { await connect() } }.disabled(key.isEmpty)
                    Button("Disconnect") { Task { if await AppModel.shared.call("linear.setKey", .obj(["key": ""])) != nil { linearStatus = String(localized: "Not connected") } } }
                }
                Text("Create a key in Linear › Settings › Security & access. It's stored in your login keychain.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let s = await AppModel.shared.call("linear.status")
            let off = String(localized: "Not connected")
            linearStatus = s?["connected"]?.bool == true ? String(localized: "Connected as \(s?["name"]?.string ?? "")") : off
            let j = await AppModel.shared.call("jira.status")
            jiraStatus = j?["connected"]?.bool == true ? String(localized: "Connected to \(j?["site"]?.string ?? "") as \(j?["name"]?.string ?? "")") : off
            bbStatus = (await AppModel.shared.call("bitbucket.status"))?["connected"]?.bool == true ? String(localized: "Credentials saved") : off
            let gh = await AppModel.shared.call("github.status")
            if gh?["installed"]?.bool != true { ghStatus = String(localized: "GitHub CLI isn't installed"); ghFix = "brew install gh" }
            else if let u = gh?["user"]?.string { ghStatus = String(localized: "Signed in as \(u)"); ghFix = nil }
            else { ghStatus = String(localized: "GitHub CLI isn't signed in (or GitHub can't be reached)"); ghFix = "gh auth login" }
        }
    }
    private func connect() async {
        if let me = await AppModel.shared.call("linear.setKey", .obj(["key": .string(key)])) {
            linearStatus = String(localized: "Connected as \(me["name"]?.string ?? "")"); key = ""
        }
    }
}
