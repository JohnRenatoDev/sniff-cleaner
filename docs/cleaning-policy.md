# Políticas de limpeza

## Princípios

O tamanho do arquivo, por si só, não autoriza o descarte. A análise é separada da remoção. Itens começam desmarcados. Nunca encerrar navegador, agente, build ou app para liberar um arquivo. Sem Full Disk Access ou sudo automático. Uma falha de acesso aparece como indisponibilidade; não como tamanho zero confirmado.

O plano vence em 15 minutos. Imediatamente antes de remover, o executor confere regras, seleção da categoria, exclusões, retenção, manifesto e processos visíveis. Repete a comparação do conteúdo depois da verificação de uso. Se o conteúdo mudou ou a verificação foi inconclusiva, o executor mantém o item e registra o motivo.

A remoção usa descritores de diretório, `openat(O_NOFOLLOW)`, `fstatat` e `unlinkat`. Não segue symlinks internos; remove o link em si. Recusa symlinks em ancestrais e fronteiras de volumes. Só entradas do manifesto são removidas. Arquivos novos ou erros podem resultar em remoção parcial, informada no histórico. Nenhuma inspeção de processos elimina a possibilidade de uma aplicação começar a usar arquivos logo depois da checagem.

## Categorias implementadas

| Categoria | Alvos reconhecidos | Remoção |
| --- | --- | --- |
| npm | `~/.npm/_cacache` | Manual / automática se habilitada |
| npx | Filhos de `~/.npm/_npx` fora da retenção | Manual; ambientes com MCP ou não reconhecidos preservados |
| uv / Bun | `~/.cache/uv`, `~/.bun/install/cache` | Manual / automática |
| pnpm | `~/Library/Caches/pnpm`, filhos de `~/Library/pnpm/store` | Manual / automática |
| pip / node-gyp | Caches conhecidos em Library/Caches e `.cache/pip` | Manual / automática |
| Go / TypeScript | `go-build` e `typescript` em Library/Caches | Manual / automática |
| SwiftPM / Homebrew | Caches em Library/Caches | Manual / automática |
| NuGet | `.local/share/NuGet/http-cache` | Manual / automática |
| Cargo | `.cargo/registry/cache`, sem fontes/toolchains | Manual / automática |
| Gradle | Filhos de `.gradle/caches` | Manual / automática |
| Codex temporário | Apenas `codex-runtime-install-*` antigos | Manual / automática |
| Instaladores | Caches de atualização reconhecidos do Codex, Granola, Bitwarden e Antigravity | Manual / automática; retenção |
| Logs | Apenas `.log` nos diretórios de logs reconhecidos | Manual; retenção própria |
| Builds Rust | `target/debug` e `target/<triple>/debug`, com `Cargo.toml`, `deps` e `.fingerprint`, inclusive em subprojetos dentro das raízes escolhidas | Manual; perfis release e toolchains preservados |
| Builds Swift | `.build` com Package.swift em raízes escolhidas | Manual; ferramentas de build ativas preservam |
| VM Claude | Somente `vm_bundles/claudevm.bundle/rootfs.img` | Manual; reconstrução avisada; Claude ativo preserva |
| Worktrees | Registros reais de `git worktree list`, raízes de projetos/Codex/Claude | Manual; apenas antigas, sem uso visível, alterações, dados locais ou commits pendentes |
| Docker / OrbStack | `system df`, containers, volumes e imagens sem tag | Somente inspeção; não inicia o engine |
| Clones de assinatura | `X/*.code_sign_clone/code_sign_clone.*` do usuário | Somente inspeção; versão e uso por inode |

### Artefatos Rust

A análise completa procura projetos Cargo também abaixo de uma raiz Git, por exemplo `SimpleMail/linux/Cargo.toml`. Cada perfil debug reconhecido aparece como um item em **Compilações**, incluindo `deps`, `incremental` e a saída dos build scripts. O Sniff não executa Cargo, `build.rs`, hooks ou filtros do projeto para descobrir esses arquivos.

A remoção exige seleção manual. O Sniff preserva o item quando há ferramentas Rust ativas, arquivos ou diretórios do projeto abertos, hardlinks em uso, inventário de processos incompleto, fontes fora da saída gerada de build scripts, configurações, bancos, credenciais, symlinks ou arquivos especiais. Em projetos Git, os artefatos também precisam estar ignorados e sem arquivos rastreados. A verificação é repetida após a conferência de uso e antes da remoção. Planos antigos para remover `target` inteiro são recusados.

`target/release`, perfis personalizados, fontes, `Cargo.lock`, toolchains e o diretório `target` em si não entram nessa regra. Pastas personalizadas por `CARGO_TARGET_DIR`, `--target-dir`, `build.target-dir` ou `build.build-dir` não são resolvidas nesta versão; não se presume que uma pasta arbitrária seja descartável. A próxima compilação debug reconstruirá os artefatos removidos. A análise rápida e o agendamento não percorrem projetos Rust.

[Layout dos artefatos: Cargo Book](https://doc.rust-lang.org/cargo/reference/build-cache.html).

### Worktrees

A análise completa e `sniff scan --worktrees` consultam os registros reais do Git, inclusive worktrees fora das pastas de projetos. Repositórios e worktrees são deduplicados por dispositivo/inode. O checkout principal nunca entra na lista de remoção.

Para oferecer uma worktree à revisão manual, o Sniff exige:

- Registro Git e diretório administrativo correspondentes, sem symlinks nos ancestrais, bloqueios ou operação Git em andamento.
- Inventário completo dos processos visíveis, sem referência ao caminho, arquivo aberto ou hardlink aberto por outro caminho.
- Ausência de alterações locais, arquivos novos, submódulos e flags que possam ocultar alterações do Git.
- Todos os commits de `HEAD`, `ORIG_HEAD` e do reflog local publicados nas referências remotas conhecidas. O `HEAD` também precisa estar integrado à principal registrada em `upstream/HEAD`, `origin/HEAD` ou em um único outro remoto com principal registrada. Não se presume `main` ou `master`.
- Arquivos ignorados limitados a dependências/compilações reconhecidas por arquivos de projeto rastreados: `node_modules`, `.next`, `.nuxt`, Rust `target`, SwiftPM `.build` e .NET `bin`/`obj`. Configurações, credenciais, bancos, estado de agentes e repositórios aninhados preservam a worktree inteira, inclusive dentro dessas pastas.
- Nenhuma escrita dentro do prazo de retenção, que é de 14 dias por padrão. Isso inclui os metadados administrativos da worktree.
- Manifesto completo, dentro dos limites de análise. Falha ou análise parcial preserva o item.

As comparações usam referências locais: não há fetch, consulta atual do servidor, hooks ou execução dos filtros clean/process do projeto. Histórico incompleto, principal desconhecida ou evidência inconclusiva impedem a remoção. Excluir o caminho do repositório principal também preserva suas worktrees externas. Categorias manuais desabilitadas não entram em planos da CLI.

A remoção exige seleção explícita e confirmação do plano. O executor repete as verificações Git e de uso, confere os manifestos e remove somente a pasta escolhida e seu diretório administrativo, usando descritores. Não executa `--force`, prune global ou exclusão de branches. O arquivo `.git` fica por último; uma falha parcial tenta manter o vínculo do Git para revisão. Mudanças nos metadados administrativos preservam o registro restante.

O Sniff não cria backups dessas worktrees. A cópia removida deve ser reconstruível pelos commits já preservados no repositório principal; dados locais importantes bloqueiam a limpeza. A limpeza de worktrees nunca entra no agendamento automático. Veja os formatos de registro na [documentação do Git](https://git-scm.com/docs/git-worktree).

Docker mostra o total e o recuperável informado pelo engine, separados do espaço APFS. Imagem sem tag não significa imagem sem container. Esta versão não executa prune, `system prune -a`, remoção de volumes ou bancos.

Clones Chromium/Electron são parte legítima do mecanismo de atualização. Uma consulta direta ao executável via `lsof` detecta uso por inode/hardlink mesmo que o caminho exibido seja outro. A existência de um clone não comprova um defeito. O Sniff não altera validação de assinatura.

## Proteções

Sessões, configurações, credenciais, fontes com alterações locais, bancos, volumes e runtime principal ficam fora das regras. Checkouts principais e branches são preservados; a exceção para cópias de código já commitadas são as worktrees que passam por todas as verificações e pela revisão manual acima. Exclusões persistentes preservam também o item pai. A VM Claude não inclui sessiondata, base comprimida ou metadados. A automação só admite categorias regeneráveis habilitadas, nunca VMs, worktrees, Docker, builds, logs, npx ou clones.

Limpeza de resíduos não corrige vazamento de processos, concorrência excessiva do Codex ou kernel panic. O Sniff não modifica o Codex nem atribui causa a incidentes.
