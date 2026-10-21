import AppKit
import SwiftUI
import Core

struct IntegrationsSettings: View {
    @State private var key = ""
    @State private var linearStatus = String(localized: "Checking…")
    @State private var gh = CLIState()
    @State private var glab = CLIState()
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
                cliRow(gh)
                Text("Kelp uses the GitHub CLI and its login. Project boards need `gh auth refresh -s read:project`.").font(.caption).foregroundStyle(.secondary)
            }
            Section("GitLab") {
                cliRow(glab)
                Text("Merge requests, issues and pipelines through the GitLab CLI (glab) and its login, self-managed hosts too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Jira") {
                Text(jiraStatus).foregroundStyle(.secondary)
                TextField("Site", text: $jiraSite, prompt: Text("acme.atlassian.net"))
                TextField("Email", text: $jiraEmail)
                SecureField("API token", text: $jiraToken)
                HStack {
                    Button("Connect") { Task {
                        if let r = await AppModel.shared.call(JiraSetCredentials(site: jiraSite, email: jiraEmail, token: jiraToken)) {
                            jiraStatus = String(localized: "Connected as \(r?.name ?? "")"); jiraToken = ""
                        }
                    } }.disabled(jiraSite.isEmpty || jiraEmail.isEmpty || jiraToken.isEmpty)
                    Button("Disconnect") { Task {
                        if await AppModel.shared.call(JiraSetCredentials(site: "", email: "", token: "")) != nil {
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
                    if await AppModel.shared.call(BitbucketSetCredentials(user: bbUser, token: bbToken)) != nil {
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
                    Button("Disconnect") { Task { if await AppModel.shared.call(LinearSetKey(key: "")) != nil { linearStatus = String(localized: "Not connected") } } }
                }
                Text("Create a key in Linear › Settings › Security & access. It's stored in your login keychain.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let s = await AppModel.shared.call(LinearStatus())
            let off = String(localized: "Not connected")
            linearStatus = s?.connected == true ? String(localized: "Connected as \(s?.name ?? "")") : off
            let j = await AppModel.shared.call(JiraStatus())
            jiraStatus = j?.connected == true ? String(localized: "Connected to \(j?.site ?? "") as \(j?.name ?? "")") : off
            bbStatus = (await AppModel.shared.call(BitbucketStatus()))?.connected == true ? String(localized: "Credentials saved") : off
            await check()
        }
    }

    /// What gh or glab can do now, and the button that sets it up in a terminal tab.
    struct CLIState { var status = String(localized: "Checking…"), setup: Forge.Setup? }

    private func cliRow(_ c: CLIState) -> some View {
        HStack {
            Text(c.status).foregroundStyle(.secondary)
            Spacer()
            if let s = c.setup {
                Button(s.title) { Forge.run(s) }.help(s.command)
                Button("Check Again") { Task { await check() } }
            }
        }
    }

    private func check() async {
        func state(_ r: GitHubStatus.Result?, _ cli: String, _ site: String) -> CLIState {
            guard let r else { return CLIState(status: String(localized: "Couldn't check")) }
            if !r.installed { return CLIState(status: String(localized: "\(site) CLI isn't installed"), setup: Forge.install(cli)) }
            if let u = r.user { return CLIState(status: String(localized: "Signed in as \(u)")) }
            return CLIState(status: String(localized: "\(site) CLI isn't signed in (or \(site) can't be reached)"), setup: Forge.signIn(cli))
        }
        gh = state(await AppModel.shared.call(GitHubStatus()), "gh", "GitHub")
        glab = state(await AppModel.shared.call(GitLabStatus()), "glab", "GitLab")
    }
    private func connect() async {
        if let me = await AppModel.shared.call(LinearSetKey(key: key)) {
            linearStatus = String(localized: "Connected as \(me?.name ?? "")"); key = ""
        }
    }
}
