import Foundation
#if os(macOS)
import AppKit
#endif

final class ExecutionService {
    static let shared = ExecutionService()

    private init() {}

    func execute(command: TravisCommand) async -> String {
        let text = command.text.lowercased()

        if text.contains("open xcode") || text.contains("άνοιξε xcode") {
            #if os(macOS)
            await openXcode()
            return "Άνοιξα το Xcode."
            #else
            return "Το Xcode action υποστηρίζεται μόνο στο Mac."
            #endif
        }

        if text.contains("βρες") || text.contains("search") || text.contains("internet") {
            return "Έτοιμος να κάνω web lookup."
        }

        return "Η εντολή καταχωρήθηκε: \(command.text)"
    }

    #if os(macOS)
    private func openXcode() async {
        let app = NSWorkspace.shared
        app.launchApplication("Xcode")
    }
    #endif
}
