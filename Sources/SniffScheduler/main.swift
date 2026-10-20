import Foundation
import SniffCore

let arguments = CommandLine.arguments
let index = arguments.firstIndex(of: "--fixture-store")
let fixture = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
let store = StateStore(directory: fixture.map { URL(fileURLWithPath: $0) } ?? StateStore().directory)
do {
    let message = try ScheduledRunner.run(store: store, fixture: fixture != nil)
    if let message { print(message) }
} catch {
    FileHandle.standardError.write(Data("Sniff: \(error.localizedDescription)\n".utf8))
    exit(1)
}
