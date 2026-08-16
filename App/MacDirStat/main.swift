import AppKit

// Programmatic AppKit lifecycle (spec §4.1): no storyboard, no document
// architecture, no `@NSApplicationMain`. The app owns its delegate, its main
// menu and its window controller outright, so the split divider, menu/
// first-responder validation and the tree↔treemap selection sync stay under
// direct control.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
