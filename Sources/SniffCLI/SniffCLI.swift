import Foundation
import Darwin
import SniffCore
import SniffCommands

@main
enum SniffCLIEntry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let jsonRequested = arguments.contains("--json")
        let languageIndex = arguments.lastIndex(of: "--language").map { $0 + 1 }
        let requestedLanguage = languageIndex.flatMap { arguments.indices.contains($0) ? AppLanguage(rawValue: arguments[$0]) : nil }
        var request: CLIRequest?
        do {
            let parsed = try CLIRequest.parse(arguments); request = parsed
            let environment = CLIEnvironment(interactive: isatty(STDIN_FILENO) == 1)
            let result = try CLIRunner(environment: environment).run(parsed, diagnostics: { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }, confirm: { message in
                FileHandle.standardError.write(Data((message + " ").utf8))
                return readLine() == "CLEAN"
            })
            FileHandle.standardOutput.write(Data((result.output + "\n").utf8))
            exit(result.status)
        } catch {
            let language = request?.language ?? requestedLanguage ?? LanguagePreference.load()
            let failure = error as? CLIFailure
            let message = failure?.message(language: language) ?? Localization.text(error.localizedDescription, language: language)
            if jsonRequested {
                let data = (try? JSONSerialization.data(withJSONObject: ["error": message, "exitCode": failure?.status ?? 1], options: [.sortedKeys])) ?? Data()
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            } else { FileHandle.standardError.write(Data(("sniff: " + message + "\n").utf8)) }
            exit(failure?.status ?? 1)
        }
    }
}
