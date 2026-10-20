import Foundation

public enum DockerInspector {
    public static func inspect(notices: inout [String]) -> [Finding] {
        guard let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", FileManager.default.homeDirectoryForCurrentUser.path + "/.orbstack/bin/docker"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { notices.append("Docker CLI não encontrado. OrbStack não foi iniciado pelo Sniff."); return [] }
        let context = Command.run(docker, ["context", "show"], timeout: 5)
        guard context.status == 0 else { notices.append("Contexto do Docker indisponível."); return [] }
        let disk = Command.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 15)
        guard disk.status == 0, !disk.timedOut else { notices.append("Docker / OrbStack sem resposta. Nenhum serviço foi iniciado."); return [] }
        let containers = Command.run(docker, ["ps", "-aq"], timeout: 5)
        let volumes = Command.run(docker, ["volume", "ls", "-q"], timeout: 5)
        let summary = "Contexto: \(context.output.trimmingCharacters(in: .whitespacesAndNewlines)). \(containers.output.split(separator: "\n").count) containers e \(volumes.output.split(separator: "\n").count) volumes preservados."
        var output: [Finding] = []
        for line in disk.output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = row["Type"] as? String else { continue }
            let details = "Total: \(row["Size"] ?? "?") · Recuperável informado pelo Docker: \(row["Reclaimable"] ?? "?") · Ativos: \(row["Active"] ?? "?")"
            output.append(.init(path: "docker://" + kind, title: kind, category: .docker, ruleID: "docker-inspect", state: .review, reason: summary, details: [details, "Contabilização do engine; não é promessa de espaço recuperado no APFS.", "Esta versão não remove imagens, cache, containers ou volumes."]))
        }
        let images = Command.run(docker, ["image", "ls", "--filter", "dangling=true", "--format", "{{.ID}} · {{.Size}} · {{.CreatedSince}}"], timeout: 6)
        if images.status == 0, !images.output.isEmpty { output.append(.init(path: "docker://dangling", title: "Imagens sem tag", category: .docker, ruleID: "docker-inspect", state: .review, reason: "Sem tag não significa sem container associado. Inspeção, sem remoção.", details: Array(images.output.components(separatedBy: .newlines).filter { !$0.isEmpty }.prefix(25)))) }
        return output
    }
}
