import Foundation
import SniffCore

public struct CLIRequest: Sendable {
    public enum Action: String, Sendable { case help, version, status, scan, list, categories, plan, clean, history, config }
    public var action: Action = .help
    public var json = false
    public var quick = false
    public var yes = false
    public var readyOnly = false
    public var output: String?
    public var planFile: String?
    public var stateDirectory: String?
    public var categories: [SniffCore.Category] = []
    public var paths: [String] = []
    public var enable: [SniffCore.Category] = []
    public var disable: [SniffCore.Category] = []
    public var projects: [String] = []
    public var exclusions: [String] = []
    public var language = LanguagePreference.load()

    public static func parse(_ arguments: [String]) throws -> CLIRequest {
        var request = CLIRequest(); var index = 0; var actionSeen = false; var informational: Action?
        func value(_ option: String) throws -> String {
            index += 1
            guard arguments.indices.contains(index), !arguments[index].hasPrefix("--") else { throw CLIFailure.usage("Missing value for {0}.", option) }
            return arguments[index]
        }
        func category(_ name: String) throws -> SniffCore.Category {
            guard let value = SniffCore.Category.allCases.first(where: { $0.cliName == name || $0.rawValue == name }) else { throw CLIFailure.usage("Unknown category: {0}. Run sniff categories.", name) }
            return value
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h": informational = .help
            case "--version", "-v": informational = .version
            case "--json": request.json = true
            case "--quick": request.quick = true
            case "--yes", "-y": request.yes = true
            case "--ready": request.readyOnly = true
            case "--output", "-o": request.output = try value(argument)
            case "--plan": request.planFile = try value(argument)
            case "--state-dir": request.stateDirectory = try value(argument)
            case "--category": request.categories.append(try category(value(argument)))
            case "--path": request.paths.append(try value(argument))
            case "--enable": request.enable.append(try category(value(argument)))
            case "--disable": request.disable.append(try category(value(argument)))
            case "--project": request.projects.append(try value(argument))
            case "--exclude": request.exclusions.append(try value(argument))
            case "--language":
                let code = try value(argument)
                guard let language = AppLanguage(rawValue: code) else { throw CLIFailure.usage("Use en, pt, es or system for --language.") }
                request.language = language
            default:
                guard !actionSeen, let action = Action(rawValue: argument) else { throw CLIFailure.usage("Unknown command or option: {0}.", argument) }
                request.action = action; actionSeen = true
            }
            index += 1
        }
        if let informational { request.action = informational; return request }
        guard request.categories.isEmpty || request.paths.isEmpty else { throw CLIFailure.usage("Use either --category or --path, not both.") }
        if request.quick && request.action != .scan { throw CLIFailure.usage("--quick is only available for scan.") }
        if request.readyOnly && request.action != .list { throw CLIFailure.usage("--ready is only available for list.") }
        if request.yes && request.action != .clean { throw CLIFailure.usage("--yes is only available for clean.") }
        if request.output != nil && request.action != .plan { throw CLIFailure.usage("--output is only available for plan.") }
        if request.planFile != nil && request.action != .clean { throw CLIFailure.usage("--plan is only available for clean.") }
        if request.action == .clean && request.planFile == nil { throw CLIFailure.usage("clean requires --plan. Create a reviewed plan with sniff plan --output first.") }
        if (!request.categories.isEmpty || !request.paths.isEmpty) && request.action != .plan && request.action != .list { throw CLIFailure.usage("Selection filters are only available for list and plan.") }
        if (!request.enable.isEmpty || !request.disable.isEmpty || !request.projects.isEmpty || !request.exclusions.isEmpty) && request.action != .config { throw CLIFailure.usage("Configuration changes require the config command.") }
        return request
    }
}

public extension SniffCore.Category {
    var cliName: String {
        switch self {
        case .nodeGyp: "node-gyp"
        case .swiftPM: "swiftpm"
        case .runtimeInstall: "runtime-installs"
        case .signingClone: "signing-copies"
        case .claudeVM: "claude-vm"
        default: rawValue
        }
    }
}

public struct CLIFailure: Error, Sendable {
    public let status: Int32
    public let key: String
    public let arguments: [String]
    public static func usage(_ key: String, _ arguments: String...) -> CLIFailure { .init(status: 2, key: key, arguments: arguments) }
    public func message(language: AppLanguage) -> String { Localization.text(key, arguments: arguments, language: language) }
}
