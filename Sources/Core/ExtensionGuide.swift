/// The extension authoring guide: docs/extensions.md verbatim (a CoreTests test keeps them equal).
/// Written to ~/.kelp/extensions/EXTENSIONS.md for agents; the app shows it too.
public enum ExtensionGuide {
    public static let markdown = #"""
    # Writing Kelp extensions

    An extension is a folder in `~/.kelp/extensions/<id>/` with an `extension.json`. No build step:
    Kelp reloads it when the files change. Commands run with `/bin/zsh -lc` in the current workspace
    directory, so anything you can do in a terminal you can surface in the IDE.

    Quick start: `kelp ext new my-thing` (or "New Extension with AI…" in the command palette).
    Useful while developing: `kelp ext list`, `kelp ext reload`, `kelp ext disable <id>`.

    ## extension.json
    ```json
    {
      "id": "docker",
      "name": "Docker",
      "version": "1.0.0",
      "description": "Containers on this Mac",
      "icon": "shippingbox",
      "contributes": {
        "panels":   [],
        "editors":  [],
        "commands": [],
        "settings": [],
        "themes":   [],
        "iconThemes": [],
        "agents":   []
      }
    }
    ```
    `icon` and every other `icon` field is an SF Symbol name (see the SF Symbols app).

    ## Views: panels (right inspector) and editors (center tabs)
    Both take the same view definitions; `editors` also appear in the editor area's "+" menu.

    ### list — rows from a command
    ```json
    {
      "id": "containers",
      "title": "Containers",
      "icon": "shippingbox",
      "list": {
        "command": "docker ps -a --format '{{json .}}'",
        "refresh": 5,
        "title": "${Names}",
        "subtitle": "${Image} · ${Status}",
        "icon": "shippingbox",
        "status": { "field": "State", "map": { "running": "working", "exited": "done", "dead": "ended" } },
        "empty": "No containers",
        "actions": [
          { "title": "Open Shell", "icon": "terminal", "terminal": "docker exec -it ${ID} sh" },
          { "title": "Logs", "icon": "text.alignleft", "terminal": "docker logs -f --tail 200 ${ID}" },
          { "title": "Stop", "icon": "stop.circle", "run": "docker stop ${ID}", "confirm": "Stop ${Names}?" },
          { "title": "Ask Agent Why It Failed", "icon": "sparkles", "agent": "Container ${Names} (${Image}) is ${Status}. Find out why." }
        ],
        "toolbar": [
          { "title": "Prune", "icon": "trash", "terminal": "docker system prune" }
        ]
      }
    }
    ```
    - `command` prints a JSON array, or one JSON object per line. Each object is a row.
    - `${Field}` reads a field of the row (`${a.b}` for nested), `${setting:key}` a setting,
      `${workspace.path}`, `${workspace.branch}`, `${project.path}`, `${file}` (the focused file).
      Inside commands, values are shell-quoted for you.
    - `status` maps a field to a status dot: `working`, `waiting`, `done`, `idle`, `ended`.
    - The first action is the default (double-click / Return); all of them are in the row's context menu.
    - `refresh`: seconds between reloads (0 = only on open and after actions).

    ### web — any UI you like
    ```json
    { "id": "dashboard", "title": "Emulator", "icon": "iphone", "web": "index.html" }
    ```
    The page (relative to the extension folder) gets `window.kelp`:
    ```js
    await kelp.exec("adb devices")            // {code, stdout, stderr}, runs in the workspace
    kelp.terminal("emulator -avd Pixel_8")    // opens a terminal tab
    kelp.open("https://localhost:3000")       // URL → browser tab, path → file tab
    kelp.agent("Write a test for the parser") // new agent tab with this prompt
    await kelp.settings.get("my.key"); await kelp.settings.set("my.key", 3)
    kelp.workspace                            // {name, path, branch, project}
    kelp.on("settings", s => …); kelp.on("workspace", w => …)
    ```

    ## Actions (list rows, toolbars, commands)
    Exactly one of:
    | key | does |
    | --- | --- |
    | `terminal` | opens a terminal tab running the command |
    | `run` | runs the command in the background; output shown only on failure |
    | `open` | opens a URL (browser tab) or a path (file tab) |
    | `agent` | starts the default agent in a new tab with this prompt |
    Optional: `confirm` (question shown first), `icon`.

    ## commands
    ```json
    { "id": "docker.prune", "title": "Docker: Prune Unused Data", "terminal": "docker system prune", "key": "cmd+shift+k", "menu": "Tools" }
    ```
    Shown in the command palette (⇧⌘P) and the menu bar: `menu` is File, Edit, View, Run, Window or Help (Tools when
    left out). `key` binds a shortcut; Settings › Keyboard can change it. `kelp run <id>` runs a command, and
    `kelp ui state` lists every command id, Kelp's own too.

    ## settings
    ```json
    { "key": "docker.refresh", "title": "Refresh interval", "type": "number", "default": 5, "description": "Seconds" }
    ```
    Types: `boolean`, `number`, `string`, `enum` (with `"options": ["a", "b"]`), `color`. A `number` with `"options": ["0", "15"]` shows as a picker of those values.
    They appear in Settings under the extension's name and in `~/.kelp/settings.json`.

    ## themes
    ```json
    {
      "id": "dracula", "name": "Dracula", "appearance": "dark",
      "terminal": { "background": "#282a36", "foreground": "#f8f8f2", "cursor": "#f8f8f2", "selection": "#44475a",
                    "palette": ["#21222c","#ff5555","#50fa7b","#f1fa8c","#bd93f9","#ff79c6","#8be9fd","#f8f8f2",
                                "#6272a4","#ff6e6e","#69ff94","#ffffa5","#d6acff","#ff92df","#a4ffff","#ffffff"] },
      "editor": { "background": "#282a36", "text": "#f8f8f2", "keyword": "#ff79c6", "string": "#f1fa8c",
                  "comment": "#6272a4", "type": "#8be9fd", "number": "#bd93f9", "function": "#50fa7b" }
    }
    ```

    ## iconThemes
    File icon themes in VS Code's format, so existing ones work unchanged:
    ```json
    { "id": "my-icons", "label": "My Icons", "path": "icons/theme.json" }
    ```
    `path` is a VS Code file icon theme: `iconDefinitions` (each with an `iconPath` to an SVG or PNG), then `file`, `folder`,
    `folderExpanded`, `fileExtensions`, `fileNames`, `folderNames`, `folderNamesExpanded`, `languageIds` and a `light` section.
    Font icons (`fontCharacter`) aren't drawn. A VS Code extension needs no `extension.json`: Settings › Extensions › Install…
    takes its `.vsix` or its folder (`package.json` → `contributes.iconThemes`). Pick the theme in Settings › Appearance › File Icons.

    ## agents
    Same format as `~/.kelp/agents/*.json`: `{ "id", "name", "command", "args", "yoloArgs", "resumeArgs", … }`.

    ## Tips for agents writing extensions
    - Start from `kelp ext new <id>`; keep everything in that folder.
    - Test the list `command` in a terminal first: it must print JSON.
    - `kelp ext reload` reloads all extensions; errors show in Settings → Extensions.

    """#
}
