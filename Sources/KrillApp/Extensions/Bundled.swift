import Foundation
import Core

/// Extensions that ship with Krill, written in the same extension.json format users and agents write.
/// They're materialized under ~/.krill/bundled-extensions and loaded like any other folder.
enum BundledExtensions {
    static let manifests: [[String: Any]] = [ports, docker, iosSimulators, android, utm, tart]

    static var dir: URL { Paths.root.appendingPathComponent("bundled-extensions") }

    /// Writes the manifests (only when they changed) and returns their folders.
    static func materialize() -> [URL] {
        manifests.compactMap { m in
            guard let id = m["id"] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
            let folder = dir.appendingPathComponent(id)
            let file = folder.appendingPathComponent("extension.json")
            if (try? Data(contentsOf: file)) != data {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            return folder
        }
    }

    static let ports: [String: Any] = [
        "id": "ports", "name": "Ports", "version": "1.0.0", "icon": "network", "requires": ["lsof"],
        "description": "Servers listening on this Mac — open them in a browser tab or stop them.",
        "contributes": ["panels": [[
            "id": "listening", "title": "Ports", "icon": "network",
            "list": [
                "command": #"lsof -nP -iTCP -sTCP:LISTEN | awk 'NR>1 {n=split($9,a,":"); k=$1":"a[n]; if (!(k in s)) {s[k]=1; printf "{\"command\":\"%s\",\"pid\":\"%s\",\"port\":\"%s\"}\n", $1, $2, a[n]}}'"#,
                "refresh": 5, "title": "localhost:${port}", "subtitle": "${command} · pid ${pid}", "icon": "network",
                "empty": "Nothing is listening",
                "actions": [
                    ["title": "Open in Browser", "icon": "safari", "open": "http://localhost:${port}"],
                    ["title": "Stop", "icon": "stop.circle", "run": "kill ${pid}", "confirm": "Stop ${command} (port ${port})?"],
                    ["title": "Ask Agent What This Is", "icon": "sparkles", "agent": "Something (${command}, pid ${pid}) is listening on port ${port}. Find out what it is and whether it belongs to this project."]
                ]
            ]
        ]]]
    ]

    static let docker: [String: Any] = [
        "id": "docker", "name": "Docker", "version": "1.0.0", "icon": "shippingbox", "requires": ["docker"],
        "description": "Containers: logs, a shell inside, start / stop, and compose.",
        "contributes": [
            "panels": [[
                "id": "containers", "title": "Containers", "icon": "shippingbox",
                "list": [
                    "command": "docker ps -a --format '{{json .}}'", "refresh": 5,
                    "title": "${Names}", "subtitle": "${Image} · ${Status}", "icon": "shippingbox", "empty": "No containers",
                    "status": ["field": "State", "map": ["running": "working", "restarting": "waiting", "exited": "done", "created": "idle", "paused": "idle", "dead": "ended"]],
                    "actions": [
                        ["title": "Logs", "icon": "text.alignleft", "terminal": "docker logs -f --tail 200 ${ID}"],
                        ["title": "Open Shell", "icon": "terminal", "terminal": "docker exec -it ${ID} sh -c 'command -v bash >/dev/null && exec bash || exec sh'"],
                        ["title": "Start", "icon": "play", "run": "docker start ${ID}"],
                        ["title": "Stop", "icon": "stop", "run": "docker stop ${ID}"],
                        ["title": "Restart", "icon": "arrow.clockwise", "run": "docker restart ${ID}"],
                        ["title": "Remove", "icon": "trash", "run": "docker rm -f ${ID}", "confirm": "Remove the container ${Names}?"],
                        ["title": "Ask Agent About It", "icon": "sparkles", "agent": "Look at the Docker container ${Names} (image ${Image}, ${Status}). Read its logs with `docker logs --tail 200 ${ID}` and tell me what's going on."]
                    ],
                    "toolbar": [
                        ["title": "Compose Up", "icon": "play.rectangle", "terminal": "docker compose up"],
                        ["title": "Prune", "icon": "trash", "terminal": "docker system prune", "confirm": "Remove stopped containers, unused networks and dangling images?"]
                    ]
                ]
            ]],
            "commands": [["id": "docker.compose.up", "title": "Docker: Compose Up", "terminal": "docker compose up"]]
        ]
    ]

    static let iosSimulators: [String: Any] = [
        "id": "ios-simulators", "name": "iOS Simulators", "version": "1.0.0", "icon": "iphone", "requires": ["xcrun", "python3"],
        "description": "Boot, open and erase simulators; stream their logs.",
        "contributes": ["panels": [[
            "id": "devices", "title": "Simulators", "icon": "iphone",
            "list": [
                "command": #"xcrun simctl list devices available -j | python3 -c "import json,sys; [print(json.dumps(dict(d, runtime=r.split('.')[-1].replace('-', ' ', 1).replace('-', '.')))) for r, ds in json.load(sys.stdin)['devices'].items() for d in ds]""#,
                "refresh": 10, "title": "${name}", "subtitle": "${runtime} · ${state}", "icon": "iphone", "empty": "No simulators",
                "status": ["field": "state", "map": ["Booted": "working", "Shutdown": "idle", "Booting": "waiting"]],
                "actions": [
                    ["title": "Boot & Open", "icon": "play", "run": "xcrun simctl boot ${udid} 2>/dev/null; open -a Simulator"],
                    ["title": "Shut Down", "icon": "stop", "run": "xcrun simctl shutdown ${udid}"],
                    ["title": "Stream Logs", "icon": "text.alignleft", "terminal": "xcrun simctl spawn ${udid} log stream --level info"],
                    ["title": "Erase", "icon": "trash", "run": "xcrun simctl erase ${udid}", "confirm": "Erase all content and settings of ${name}?"]
                ]
            ]
        ]]]
    ]

    static let android: [String: Any] = [
        "id": "android-emulators", "name": "Android Emulators", "version": "1.0.0", "icon": "candybarphone", "requires": ["emulator"],
        "description": "Launch AVDs, cold boot or wipe them; adb devices and logcat.",
        "contributes": ["panels": [[
            "id": "avds", "title": "Emulators", "icon": "candybarphone",
            "list": [
                "command": #"emulator -list-avds | awk 'NF && $0 !~ /^INFO/ {printf "{\"name\":\"%s\"}\n", $0}'"#,
                "refresh": 0, "title": "${name}", "icon": "candybarphone", "empty": "No virtual devices — create one in Android Studio",
                "actions": [
                    ["title": "Launch", "icon": "play", "terminal": "emulator -avd ${name}"],
                    ["title": "Cold Boot", "icon": "power", "terminal": "emulator -avd ${name} -no-snapshot-load"],
                    ["title": "Wipe Data", "icon": "trash", "terminal": "emulator -avd ${name} -wipe-data", "confirm": "Wipe all data of ${name}?"]
                ],
                "toolbar": [
                    ["title": "Devices", "icon": "list.bullet", "terminal": "adb devices -l"],
                    ["title": "Logcat", "icon": "text.alignleft", "terminal": "adb logcat"]
                ]
            ]
        ]]]
    ]

    static let utm: [String: Any] = [
        "id": "utm", "name": "Virtual Machines (UTM)", "version": "1.0.0", "icon": "desktopcomputer",
        "requires": ["/Applications/UTM.app/Contents/MacOS/utmctl"],
        "description": "Start, stop and suspend UTM virtual machines.",
        "contributes": ["panels": [[
            "id": "vms", "title": "Virtual Machines", "icon": "desktopcomputer",
            "list": [
                "command": #"/Applications/UTM.app/Contents/MacOS/utmctl list | awk 'NR>1 {u=$1; st=$2; $1=""; $2=""; sub(/^ +/, ""); printf "{\"uuid\":\"%s\",\"status\":\"%s\",\"name\":\"%s\"}\n", u, st, $0}'"#,
                "refresh": 5, "title": "${name}", "subtitle": "${status}", "icon": "desktopcomputer", "empty": "No virtual machines",
                "status": ["field": "status", "map": ["started": "working", "paused": "idle", "stopped": "done", "starting": "waiting"]],
                "actions": [
                    ["title": "Start", "icon": "play", "run": "/Applications/UTM.app/Contents/MacOS/utmctl start ${uuid}"],
                    ["title": "Stop", "icon": "stop", "run": "/Applications/UTM.app/Contents/MacOS/utmctl stop ${uuid}"],
                    ["title": "Suspend", "icon": "pause", "run": "/Applications/UTM.app/Contents/MacOS/utmctl suspend ${uuid}"],
                    ["title": "Show in UTM", "icon": "macwindow", "run": "open -a UTM"]
                ]
            ]
        ]]]
    ]

    static let tart: [String: Any] = [
        "id": "tart", "name": "Virtual Machines (Tart)", "version": "1.0.0", "icon": "shippingbox.circle", "requires": ["tart"],
        "description": "macOS and Linux VMs with Tart: run, stop, SSH in.",
        "contributes": ["panels": [[
            "id": "vms", "title": "Tart VMs", "icon": "shippingbox.circle",
            "list": [
                "command": "tart list --format json", "refresh": 5,
                "title": "${Name}", "subtitle": "${Source} · ${State} · ${Disk} GB", "icon": "shippingbox.circle", "empty": "No VMs — `tart clone` one",
                "status": ["field": "State", "map": ["running": "working", "stopped": "done", "suspended": "idle"]],
                "actions": [
                    ["title": "Run", "icon": "play", "terminal": "tart run ${Name}"],
                    ["title": "SSH", "icon": "terminal", "terminal": "ssh admin@$(tart ip ${Name})"],
                    ["title": "Stop", "icon": "stop", "run": "tart stop ${Name}"],
                    ["title": "Delete", "icon": "trash", "run": "tart delete ${Name}", "confirm": "Delete the VM ${Name}?"]
                ]
            ]
        ]]]
    ]
}
