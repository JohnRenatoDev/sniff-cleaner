# Políticas de limpeza — 0.1

## Princípios

Tamanho grande não é evidência de descarte. A análise é separada da remoção. Itens começam desmarcados. Nunca encerrar navegador, agente, build ou app para liberar um arquivo. Sem Full Disk Access ou sudo automático. Uma falha de acesso aparece como indisponibilidade; não como tamanho zero confirmado.

O plano vence em 15 minutos. Imediatamente antes de remover, o executor confere regras, seleção da categoria, exclusões, retenção, manifesto e processos visíveis. Repete a comparação do conteúdo depois da verificação de uso. Mudança ou incerteza preserva o item e produz um resultado individual.

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
| Builds | `target` com Cargo.toml e `.build` com Package.swift em raízes escolhidas | Manual; ferramentas de build ativas preservam |
| VM Claude | Somente `vm_bundles/claudevm.bundle/rootfs.img` | Manual; reconstrução avisada; Claude ativo preserva |
| Worktrees | Registros reais de `git worktree list`, raízes de projetos/Codex/Claude | Somente inspeção |
| Docker / OrbStack | `system df`, containers, volumes e imagens sem tag | Somente inspeção; não inicia o engine |
| Clones de assinatura | `X/*.code_sign_clone/code_sign_clone.*` do usuário | Somente inspeção; versão e uso por inode |

O inventário de worktrees consulta dirty/untracked, ignorados, branch e commits exclusivos frente à principal registrada em `upstream/HEAD` ou `origin/HEAD`. Não assume `main`, não faz fetch nem afirma que a referência local está atualizada. Arquivamento conservador com snapshot/restauração e comparação atual do servidor fica para uma próxima versão. Um Git limpo não autoriza remoção.

Docker mostra o total e o recuperável informado pelo engine, separados do espaço APFS. Imagem sem tag não significa imagem sem container. Esta versão não executa prune, `system prune -a`, remoção de volumes ou bancos.

Clones Chromium/Electron são parte legítima do mecanismo de atualização. Uma consulta direta ao executável via `lsof` detecta uso por inode/hardlink mesmo que o caminho exibido seja outro. Existência do clone não comprova bug. O Sniff não altera validação de assinatura.

## Proteções

Sessões, configurações, credenciais, fontes, bancos, volumes e runtime principal ficam fora das regras. Exclusões persistentes preservam também o item pai. A VM Claude não inclui sessiondata, base comprimida ou metadados. A automação só admite categorias regeneráveis habilitadas, nunca VMs, worktrees, Docker, builds, logs, npx ou clones.

Limpeza de resíduos não corrige vazamento de processos, concorrência excessiva do Codex ou kernel panic. O Sniff não modifica o Codex nem atribui causa a incidentes.
