import AppKit

// Loads bundled images in a way that works from both a packaged .app (where
// package-app.sh drops the PNGs into Contents/Resources so the .app is a clean,
// codesign-able bundle) and from `swift run` (where they live in the SwiftPM
// resource bundle reached via Bundle.module).
enum AppResources {
    static func image(_ name: String) -> NSImage? {
        // .app: Contents/Resources via Bundle.main. Checked first so Bundle.module
        // (which fatalErrors if the SwiftPM bundle is absent) is never touched here.
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return Bundle.module.image(forResource: name)
    }
}
