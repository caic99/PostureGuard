import AppKit

let config = Config.load(arguments: CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
