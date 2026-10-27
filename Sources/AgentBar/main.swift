import AppKit

ShellEnvironmentResolver.printEnvironmentIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
