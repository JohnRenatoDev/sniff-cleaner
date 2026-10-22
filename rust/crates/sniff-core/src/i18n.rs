//! English, Portuguese and Spanish text. Messages are stored as keys with
//! arguments and rendered here, so persisted state is language-neutral.

use crate::model::{Msg, MsgArg};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    En,
    Pt,
    Es,
}

impl Lang {
    pub fn code(self) -> &'static str {
        match self {
            Lang::En => "en",
            Lang::Pt => "pt",
            Lang::Es => "es",
        }
    }

    /// `en`, `pt`, `es` and regional variants such as `pt-BR` or `es_AR`.
    pub fn parse_choice(s: &str) -> Option<Lang> {
        let primary = s.split(['-', '_', '.', '@']).next().unwrap_or("").to_ascii_lowercase();
        match primary.as_str() {
            "en" => Some(Lang::En),
            "pt" => Some(Lang::Pt),
            "es" => Some(Lang::Es),
            _ => None,
        }
    }

    /// First match among a list of preferred locales; English otherwise.
    pub fn from_locales<'a>(locales: impl IntoIterator<Item = &'a str>) -> Lang {
        locales.into_iter().find_map(Lang::parse_choice).unwrap_or(Lang::En)
    }

    /// Per-invocation choice, then saved preference, then the environment.
    pub fn resolve(saved: &str, invocation: Option<&str>) -> Lang {
        for choice in [invocation, Some(saved)].into_iter().flatten() {
            if choice != "system" {
                if let Some(l) = Lang::parse_choice(choice) {
                    return l;
                }
            }
        }
        let mut locales: Vec<String> = Vec::new();
        if let Ok(v) = std::env::var("LANGUAGE") {
            locales.extend(v.split(':').map(str::to_string));
        }
        for k in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let Ok(v) = std::env::var(k) {
                locales.push(v);
            }
        }
        Lang::from_locales(
            locales
                .iter()
                .map(String::as_str)
                .filter(|s| !s.is_empty() && *s != "C" && *s != "POSIX"),
        )
    }
}

/// (key, English, Portuguese, Spanish)
pub static CATALOG: &[(&str, &str, &str, &str)] = &[
    // Categories
    ("category.npm", "npm cache", "Cache do npm", "Caché de npm"),
    ("category.npx", "npx environments", "Ambientes npx", "Entornos npx"),
    ("category.uv", "uv cache", "Cache do uv", "Caché de uv"),
    ("category.bun", "Bun cache", "Cache do Bun", "Caché de Bun"),
    ("category.pnpm", "pnpm cache and store", "Cache e store do pnpm", "Caché y almacén de pnpm"),
    ("category.pip", "pip cache", "Cache do pip", "Caché de pip"),
    ("category.node-gyp", "node-gyp headers", "Cabeçalhos do node-gyp", "Cabeceras de node-gyp"),
    ("category.go", "Go build cache", "Cache de build do Go", "Caché de compilación de Go"),
    ("category.typescript", "TypeScript typings cache", "Cache de tipos do TypeScript", "Caché de tipos de TypeScript"),
    ("category.nuget", "NuGet HTTP cache", "Cache HTTP do NuGet", "Caché HTTP de NuGet"),
    ("category.cargo", "Cargo download cache", "Cache de downloads do Cargo", "Caché de descargas de Cargo"),
    ("category.gradle", "Gradle caches", "Caches do Gradle", "Cachés de Gradle"),
    ("category.runtime-installs", "Temporary Codex installs", "Instalações temporárias do Codex", "Instalaciones temporales de Codex"),
    ("category.logs", "Old logs", "Logs antigos", "Registros antiguos"),
    ("category.build", "Project builds", "Compilações de projetos", "Compilaciones de proyectos"),
    ("category.worktree", "Git worktrees", "Worktrees do Git", "Worktrees de Git"),
    ("category.docker", "Docker", "Docker", "Docker"),
    // States
    ("state.ready", "Ready to clean", "Pode limpar", "Se puede limpiar"),
    ("state.in_use", "In use", "Em uso", "En uso"),
    ("state.protected", "Preserved", "Preservado", "Conservado"),
    ("state.review", "Needs review", "Exige revisão", "Requiere revisión"),
    ("state.inaccessible", "No access", "Sem acesso", "Sin acceso"),
    ("wtstatus.idle", "Idle and clean", "Ociosa e limpa", "Inactiva y limpia"),
    ("wtstatus.in_use", "In use", "Em uso", "En uso"),
    ("wtstatus.local_changes", "Local changes", "Alterações locais", "Cambios locales"),
    ("wtstatus.pending_commits", "Pending commits", "Commits pendentes", "Commits pendientes"),
    ("wtstatus.local_data", "Local data", "Dados locais", "Datos locales"),
    ("wtstatus.locked", "Locked", "Bloqueada", "Bloqueada"),
    ("wtstatus.recent", "Recently changed", "Alterada recentemente", "Cambiada recientemente"),
    ("wtstatus.excluded", "Excluded", "Excluída", "Excluida"),
    ("wtstatus.missing", "Missing", "Ausente", "Ausente"),
    ("wtstatus.unverified", "Not verified", "Não verificada", "No verificada"),
    // Titles
    ("title.plain", "{0}", "{0}", "{0}"),
    ("title.build", "{0} / {1}", "{0} / {1}", "{0} / {1}"),
    // Progress
    ("progress.sniffing", "Sniffing {0}…", "Farejando {0}…", "Olfateando {0}…"),
    ("progress.projects", "Looking for projects…", "Procurando projetos…", "Buscando proyectos…"),
    ("progress.worktrees", "Checking worktrees…", "Conferindo worktrees…", "Revisando worktrees…"),
    ("progress.docker", "Checking Docker…", "Conferindo o Docker…", "Revisando Docker…"),
    // Reasons
    ("reason.rule_ready", "This path matches a cleanup rule. Sniff checks it again before removing anything.", "Este caminho está nas regras de limpeza. O Sniff vai conferir o item de novo antes de remover.", "Esta ruta coincide con una regla de limpieza. Sniff la vuelve a comprobar antes de eliminar nada."),
    ("reason.logs_manual", "Old log file. Review it before removing; logs are never cleaned automatically.", "Arquivo de log antigo. Revise antes de remover; logs nunca são limpos automaticamente.", "Archivo de registro antiguo. Revísalo antes de eliminarlo; los registros nunca se limpian automáticamente."),
    ("reason.protected_path", "Protected data, settings or main runtime.", "Dados, configurações ou runtime principal protegidos.", "Datos, ajustes o runtime principal protegidos."),
    ("reason.excluded", "Kept by your exclusion: {0}", "Preservado por uma exclusão sua: {0}", "Conservado por tu exclusión: {0}"),
    ("reason.symlink_path", "Path with a symbolic link. Preserved.", "Caminho com link simbólico preservado.", "Ruta con enlace simbólico. Conservada."),
    ("reason.no_access", "No permission to read part of this item. Preserved.", "Sem permissão para ler parte deste item. Preservado.", "Sin permiso para leer parte de este elemento. Conservado."),
    ("reason.missing", "The item no longer exists.", "O item não existe mais.", "El elemento ya no existe."),
    ("reason.io_error", "Read error: {0}", "Erro de leitura: {0}", "Error de lectura: {0}"),
    ("reason.partial_limit", "Partial analysis: file or depth limit reached. Item preserved.", "Análise parcial: limite de arquivos ou profundidade. Item preservado.", "Análisis parcial: se alcanzó el límite de archivos o profundidad. Elemento conservado."),
    ("reason.other_volume", "Another volume or subvolume was found inside. Item preserved.", "Outro volume ou subvolume encontrado. Item preservado.", "Se encontró otro volumen o subvolumen. Elemento conservado."),
    ("reason.non_utf8", "A file name could not be read reliably. Item preserved.", "Um nome de arquivo não pôde ser lido com segurança. Item preservado.", "No se pudo leer un nombre de archivo con seguridad. Elemento conservado."),
    ("reason.changed_during_scan", "The item changed during the scan. Preserved; scan again.", "O item mudou durante a análise. Preservado; analise novamente.", "El elemento cambió durante el análisis. Conservado; vuelve a analizar."),
    ("reason.recent", "The item changed within the last {0} days and was preserved.", "O item teve alterações nos últimos {0} dias e foi preservado.", "El elemento cambió en los últimos {0} días y se ha conservado."),
    ("reason.npx_mcp", "npx environment with MCP or content that cannot be verified. Preserved.", "Ambiente npx com MCP ou conteúdo não verificável. Item preservado.", "Entorno npx con MCP o contenido no verificable. Conservado."),
    ("reason.process_inventory_incomplete", "Sniff could not check every visible process and preserved this item.", "O Sniff não conseguiu verificar todos os processos visíveis e preservou este item.", "Sniff no pudo comprobar todos los procesos visibles y conservó este elemento."),
    ("reason.open_by_process", "A visible process has files or a folder of this path open.", "Um processo visível mantém arquivos ou uma pasta deste caminho abertos.", "Un proceso visible tiene abiertos archivos o una carpeta de esta ruta."),
    ("reason.command_references", "A running process refers to this path.", "Um processo em execução faz referência a este caminho.", "Un proceso en ejecución hace referencia a esta ruta."),
    ("reason.hardlink_open", "A process has a hardlink of this item open through another path. Preserved.", "Um processo mantém um hardlink deste item aberto em outro caminho. Preservado.", "Un proceso tiene abierto un enlace duro de este elemento desde otra ruta. Conservado."),
    ("reason.active_tool", "Active tool: {0}.", "Ferramenta ativa: {0}.", "Herramienta activa: {0}."),
    ("reason.docker_not_running", "The Docker engine is not running. Sniff does not start it.", "O engine do Docker não está em execução. O Sniff não o inicia.", "El motor de Docker no está en ejecución. Sniff no lo inicia."),
    ("reason.docker_unavailable", "Docker did not answer. Nothing was changed.", "O Docker não respondeu. Nada foi alterado.", "Docker no respondió. No se cambió nada."),
    ("reason.docker_preserved", "Reported by Docker. Containers, images and volumes are preserved.", "Informado pelo Docker. Containers, imagens e volumes são preservados.", "Informado por Docker. Contenedores, imágenes y volúmenes se conservan."),
    // Details
    ("detail.external_links", "{0} files are also linked from outside this item; removing them frees no space.", "{0} arquivos também têm links fora deste item; removê-los não libera espaço.", "{0} archivos también tienen enlaces fuera de este elemento; eliminarlos no libera espacio."),
    ("detail.docker_inspect_only", "Inspection only: Sniff never runs prune or removes containers, images or volumes.", "Somente inspeção: o Sniff nunca executa prune nem remove containers, imagens ou volumes.", "Solo inspección: Sniff nunca ejecuta prune ni elimina contenedores, imágenes o volúmenes."),
    ("detail.docker_df", "Total: {0} · Reclaimable according to Docker: {1} · Active: {2}", "Total: {0} · Recuperável informado pelo Docker: {1} · Ativos: {2}", "Total: {0} · Recuperable según Docker: {1} · Activos: {2}"),
    ("detail.branch", "Branch: {0}", "Branch: {0}", "Rama: {0}"),
    ("detail.detached", "Branch: detached HEAD", "Branch: HEAD destacado", "Rama: HEAD separado"),
    ("detail.git_clean", "Git reports no local or untracked changes.", "Git sem alterações locais ou untracked.", "Git no informa cambios locales ni archivos sin seguimiento."),
    ("detail.git_dirty", "There are local or untracked changes.", "Há alterações locais ou arquivos untracked.", "Hay cambios locales o archivos sin seguimiento."),
    ("detail.ignored_count", "{0} paths ignored by Git.", "{0} caminhos ignorados pelo Git.", "{0} rutas ignoradas por Git."),
    ("detail.ignored", "Ignored: {0}", "Ignorado: {0}", "Ignorado: {0}"),
    ("detail.local_metadata", "Local metadata: {0}", "Metadado local: {0}", "Metadato local: {0}"),
    ("detail.unpublished", "Unpublished commits: {0}.", "Commits não publicados: {0}.", "Commits no publicados: {0}."),
    ("detail.principal", "Recorded default branch: {0}. Local reference; no fetch was run.", "Principal registrada: {0}. Referência local; nenhum fetch executado.", "Rama principal registrada: {0}. Referencia local; no se ejecutó fetch."),
    ("detail.unmerged", "Commits not in that reference: {0}.", "Commits exclusivos frente a essa referência: {0}.", "Commits que no están en esa referencia: {0}."),
    ("detail.local_refs_only", "The comparison uses local Git references; the server was not contacted.", "A comparação usa referências locais do Git; o servidor não foi consultado.", "La comparación usa referencias locales de Git; no se consultó el servidor."),
    ("detail.no_backup", "No backup is made. Only a redundant copy that Git can recreate is removed; the branch and main checkout stay.", "Nenhum backup é feito. Só é removida uma cópia redundante que o Git pode recriar; a branch e o checkout principal ficam.", "No se hace copia de seguridad. Solo se elimina una copia redundante que Git puede recrear; la rama y el checkout principal se mantienen."),
    // Worktrees
    ("wt.unverified_generic", "Not every condition of this worktree could be verified. Preserved.", "Não foi possível verificar todas as condições desta worktree. Preservada.", "No se pudieron verificar todas las condiciones de esta worktree. Conservada."),
    ("wt.missing", "Registered without a directory, or the path has a symlink. Nothing is removed.", "Registro sem diretório presente ou caminho com symlink. Nenhuma remoção.", "Registrada sin directorio o con un enlace simbólico en la ruta. No se elimina nada."),
    ("wt.locked", "Worktree locked in Git. Preserved.", "Worktree bloqueada no Git. Preservada.", "Worktree bloqueada en Git. Conservada."),
    ("wt.git_operation", "A Git operation is in progress. Worktree preserved.", "Há uma operação Git em andamento. Worktree preservada.", "Hay una operación de Git en curso. Worktree conservada."),
    ("wt.local_metadata", "The worktree has local settings or metadata that must be kept.", "A worktree tem configurações ou metadados locais que precisam ser preservados.", "La worktree tiene ajustes o metadatos locales que deben conservarse."),
    ("wt.incomplete_history", "Incomplete or altered Git history. Worktree preserved.", "Histórico Git incompleto ou alterado. Worktree preservada.", "Historial de Git incompleto o alterado. Worktree conservada."),
    ("wt.record_changed", "The worktree record changed. Preserved; scan again.", "O registro da worktree mudou. Preservada; analise novamente.", "El registro de la worktree cambió. Conservada; vuelve a analizar."),
    ("wt.submodules", "Worktree with submodules. Content kept for review.", "Worktree com submódulos. Conteúdo preservado para revisão.", "Worktree con submódulos. Contenido conservado para revisión."),
    ("wt.hidden_changes", "Git may be hiding changes in this worktree. Preserved.", "O Git pode ocultar alterações nesta worktree. Preservada.", "Git podría ocultar cambios en esta worktree. Conservada."),
    ("wt.no_remote_refs", "No local remote references to check commits against. Worktree preserved.", "Sem referências remotas locais para conferir os commits. Worktree preservada.", "No hay referencias remotas locales para comprobar los commits. Worktree conservada."),
    ("wt.local_changes", "There are local changes or new files. Worktree preserved.", "Há alterações locais ou arquivos novos. Worktree preservada.", "Hay cambios locales o archivos nuevos. Worktree conservada."),
    ("wt.pending_commits", "There are unpublished commits or commits not yet in the default branch. Worktree preserved.", "Há commits não publicados ou ainda não integrados à principal. Worktree preservada.", "Hay commits no publicados o aún no integrados en la rama principal. Worktree conservada."),
    ("wt.no_principal", "The real default branch is not recorded in local Git. main/master is not assumed.", "Branch principal real não registrada no Git local. Não presumida como main/master.", "La rama principal real no está registrada en Git local. No se asume main/master."),
    ("wt.reflog_commits", "The worktree's local history contains unpublished commits. Preserved.", "O histórico local da worktree contém commits não publicados. Preservada.", "El historial local de la worktree contiene commits no publicados. Conservada."),
    ("wt.ignored_state", "Ignored files may hold settings, data or local state. Worktree preserved.", "Há arquivos ignorados que podem conter configuração, dados ou estado local. Worktree preservada.", "Hay archivos ignorados que pueden contener ajustes, datos o estado local. Worktree conservada."),
    ("wt.add_project_root", "Add the repository to your project folders before cleaning this worktree.", "Adicione o repositório às pastas de projetos antes de limpar esta worktree.", "Añade el repositorio a tus carpetas de proyectos antes de limpiar esta worktree."),
    ("wt.nested_repository", "There is another repository inside the worktree. Content kept for review.", "Há outro repositório dentro da worktree. Conteúdo preservado para revisão.", "Hay otro repositorio dentro de la worktree. Contenido conservado para revisión."),
    ("wt.special_files", "The worktree has special files or local services. Preserved.", "Há arquivos especiais ou serviços locais nesta worktree. Preservada.", "La worktree tiene archivos especiales o servicios locales. Conservada."),
    ("wt.changed_during_scan", "The worktree changed during the scan. Preserved; scan again.", "A worktree mudou durante a análise. Preservada; analise novamente.", "La worktree cambió durante el análisis. Conservada; vuelve a analizar."),
    ("wt.ready", "No visible use, local changes or pending commits. Available for manual review.", "Sem uso visível, alterações locais ou commits pendentes. Worktree disponível para revisão manual.", "Sin uso visible, cambios locales ni commits pendientes. Disponible para revisión manual."),
    ("wt.changed_since_plan", "The worktree changed or gained pending work. Preserved; scan again.", "A worktree mudou ou ganhou pendências. Preservada; analise novamente.", "La worktree cambió o tiene trabajo pendiente. Conservada; vuelve a analizar."),
    ("wt.not_recognized", "Worktree without a safety proof. Scan again.", "Worktree sem comprovação de segurança. Analise novamente.", "Worktree sin comprobación de seguridad. Vuelve a analizar."),
    ("wt.admin_needs_review", "The folder was removed, but the Git record needs review.", "A pasta foi removida, mas o registro Git precisa de revisão.", "La carpeta se eliminó, pero el registro de Git necesita revisión."),
    // Removal
    ("removal.unknown", "Removal stopped.", "A remoção parou.", "La eliminación se detuvo."),
    ("removal.unreachable", "A directory changed, is not accessible or became a link. Preserved.", "Um diretório mudou, está sem acesso ou virou um link. Preservado.", "Un directorio cambió, no es accesible o se convirtió en un enlace. Conservado."),
    ("removal.new_entry", "A new file appeared after the scan: {0}", "Um arquivo novo apareceu depois da análise: {0}", "Apareció un archivo nuevo después del análisis: {0}"),
    ("removal.changed", "Item changed after the scan: {0}. Preserved.", "Item mudou depois da análise: {0}. Preservado.", "El elemento cambió después del análisis: {0}. Conservado."),
    ("removal.missing", "Item is no longer available: {0}", "Item não está mais disponível: {0}", "El elemento ya no está disponible: {0}"),
    ("removal.failed", "Could not remove {0} (error {1}).", "Não foi possível remover {0} (erro {1}).", "No se pudo eliminar {0} (error {1})."),
    // Executor
    ("exec.expired", "The scan has expired. Scan again before cleaning.", "A análise venceu. Analise novamente antes de limpar.", "El análisis caducó. Vuelve a analizar antes de limpiar."),
    ("exec.not_recognized", "Item outside the recognized removal rules.", "Item fora das regras de remoção reconhecidas.", "Elemento fuera de las reglas de eliminación reconocidas."),
    ("exec.category_not_allowed", "Category not allowed for this cleanup.", "Categoria não autorizada para esta limpeza.", "Categoría no autorizada para esta limpieza."),
    ("exec.duplicate", "Duplicate item or contained in another plan item.", "Item duplicado ou contido em outro item do plano.", "Elemento duplicado o contenido en otro elemento del plan."),
    ("exec.content_changed", "Content changed since the scan. Preserved; scan again.", "Conteúdo mudou desde a análise. Preservado; analise novamente.", "El contenido cambió desde el análisis. Conservado; vuelve a analizar."),
    ("exec.retention", "Retention changed or the item is recent. Preserved.", "Retenção alterada ou item recente. Preservado.", "La retención cambió o el elemento es reciente. Conservado."),
    ("exec.changed_during_check", "The item changed during the usage check. Preserved.", "Item mudou durante a verificação de uso. Preservado.", "El elemento cambió durante la comprobación de uso. Conservado."),
    ("exec.removed", "Removed after revalidation.", "Removido após revalidação.", "Eliminado tras revalidación."),
    ("exec.partial", "Partial cleanup. Some files were removed; scan again. {0}", "Limpeza parcial. Alguns arquivos foram removidos; analise novamente. {0}", "Limpieza parcial. Se eliminaron algunos archivos; vuelve a analizar. {0}"),
    // Notices
    ("notice.allocation_estimate", "Allocated sizes are estimates. Hardlinks, reflinks, compression and Btrfs snapshots can make the freed space differ; the measured change appears in the cleanup result.", "Tamanhos alocados são estimativas. Hardlinks, reflinks, compressão e snapshots do Btrfs podem fazer o espaço liberado ser diferente; a variação medida aparece no resultado da limpeza.", "Los tamaños asignados son estimaciones. Enlaces duros, reflinks, compresión e instantáneas de Btrfs pueden hacer que el espacio liberado sea distinto; la variación medida aparece en el resultado de la limpieza."),
    ("notice.visible_processes", "Usage is checked only among processes visible to your user. Another program can start using a file after the check.", "Uso verificado apenas entre processos visíveis ao seu usuário. Outro programa pode começar a usar um arquivo depois da verificação.", "El uso se comprueba solo entre procesos visibles para tu usuario. Otro programa puede empezar a usar un archivo después de la comprobación."),
    ("notice.process_inventory_incomplete", "Sniff could not check every process and preserved the files.", "O Sniff não conseguiu verificar todos os processos e preservou os arquivos.", "Sniff no pudo comprobar todos los procesos y conservó los archivos."),
    ("notice.worktrees_only", "Worktree-only scan. Run a full scan to see caches and other categories.", "Análise somente de worktrees. Use a análise completa para ver caches e outras categorias.", "Análisis solo de worktrees. Ejecuta un análisis completo para ver cachés y otras categorías."),
    ("notice.discovery_limited", "Project discovery stopped at 7,000 folders. Choose narrower project folders.", "Descoberta de projetos limitada a 7.000 pastas. Escolha pastas de projetos mais específicas.", "La búsqueda de proyectos se detuvo en 7.000 carpetas. Elige carpetas de proyectos más concretas."),
    ("notice.project_no_access", "Project folder without access: {0}", "Pasta de projeto sem acesso: {0}", "Carpeta de proyecto sin acceso: {0}"),
    ("notice.no_access", "No access: {0}", "Sem acesso: {0}", "Sin acceso: {0}"),
    ("notice.logs_partial", "Log folder only partly scanned: {0}", "Pasta de logs analisada parcialmente: {0}", "Carpeta de registros analizada parcialmente: {0}"),
    // Scheduler
    ("schedule.fixture_run", "Scheduler ran in fixture mode; nothing was scanned or removed.", "Agendador executado em fixture; nenhuma análise ou limpeza.", "Programador ejecutado en modo de prueba; no se analizó ni eliminó nada."),
    ("schedule.disabled", "Scheduling is off in Sniff settings; nothing was done.", "O agendamento está desligado nos ajustes do Sniff; nada foi feito.", "La programación está desactivada en los ajustes de Sniff; no se hizo nada."),
    ("schedule.deferred", "Postponed: a build is running or the process check was incomplete.", "Adiado: compilação ativa ou verificação de processos incompleta.", "Aplazado: hay una compilación en curso o la comprobación de procesos fue incompleta."),
    ("schedule.analyzed", "Scheduled scan finished: {0} items can be reviewed in Sniff.", "Análise agendada concluída: {0} itens podem ser revisados no Sniff.", "Análisis programado terminado: {0} elementos se pueden revisar en Sniff."),
    ("schedule.cleaned", "Scheduled cleanup: {0} items removed. See the history.", "Limpeza agendada: {0} itens removidos. Consulte o histórico.", "Limpieza programada: {0} elementos eliminados. Consulta el historial."),
    ("schedule.foreign_unit", "A unit file not created by Sniff already exists: {0}", "Já existe um arquivo de unidade que não foi criado pelo Sniff: {0}", "Ya existe un archivo de unidad no creado por Sniff: {0}"),
    ("schedule.systemctl_failed", "systemd did not accept the user timer. Check systemctl --user.", "O systemd não aceitou o timer do usuário. Confira systemctl --user.", "systemd no aceptó el temporizador de usuario. Revisa systemctl --user."),
    // CLI
    ("cli.no_home", "HOME is not set.", "HOME não está definido.", "HOME no está definido."),
    ("cli.busy", "Another Sniff scan or cleanup is in progress.", "Outra análise ou limpeza do Sniff está em andamento.", "Hay otro análisis o limpieza de Sniff en curso."),
    ("cli.state_corrupt", "Saved state could not be read: {0}. Keep a copy before repairing it; it will not be overwritten.", "O estado salvo não pôde ser lido: {0}. Guarde uma cópia antes de reparar; ele não será sobrescrito.", "No se pudo leer el estado guardado: {0}. Guarda una copia antes de repararlo; no se sobrescribirá."),
    ("cli.state_insecure", "State path is not a private regular file: {0}. Nothing was overwritten.", "O caminho de estado não é um arquivo regular privado: {0}. Nada foi sobrescrito.", "La ruta de estado no es un archivo normal privado: {0}. No se sobrescribió nada."),
    ("cli.no_scan", "No saved scan. Run sniff scan first.", "Nenhuma análise salva. Rode sniff scan primeiro.", "No hay ningún análisis guardado. Ejecuta sniff scan primero."),
    ("cli.path_not_in_scan", "Path not found in the saved scan: {0}.", "Caminho não encontrado na análise salva: {0}.", "Ruta no encontrada en el análisis guardado: {0}."),
    ("cli.no_eligible", "No eligible items selected. Check the scan and enabled categories.", "Nenhum item elegível selecionado. Confira a análise e as categorias habilitadas.", "No hay elementos aptos seleccionados. Revisa el análisis y las categorías habilitadas."),
    ("cli.plan_expired", "The plan has expired. Scan again and create a new plan.", "O plano venceu. Analise novamente e crie um novo plano.", "El plan caducó. Vuelve a analizar y crea un plan nuevo."),
    ("cli.plan_too_large", "The plan is too large. Select fewer items.", "O plano ficou grande demais. Selecione menos itens.", "El plan es demasiado grande. Selecciona menos elementos."),
    ("cli.plan_cannot_create", "Cannot create plan at {0}. Choose a new file name in an existing folder.", "Não foi possível criar o plano em {0}. Escolha um nome novo em uma pasta existente.", "No se pudo crear el plan en {0}. Elige un nombre nuevo en una carpeta existente."),
    ("cli.plan_invalid", "Invalid plan file.", "Arquivo de plano inválido.", "Archivo de plan no válido."),
    ("cli.plan_foreign", "This plan is empty, unsupported or belongs to another home folder.", "Este plano está vazio, não é suportado ou pertence a outra pasta pessoal.", "Este plan está vacío, no es compatible o pertenece a otra carpeta personal."),
    ("cli.plan_duplicates", "The plan contains duplicate paths.", "O plano contém caminhos duplicados.", "El plan contiene rutas duplicadas."),
    ("cli.noninteractive_needs_yes", "Non-interactive cleanup requires --yes and an explicit plan file.", "Limpeza não interativa exige --yes e um arquivo de plano explícito.", "La limpieza no interactiva requiere --yes y un archivo de plan explícito."),
    ("cli.type_clean", "Type CLEAN to permanently delete these files and folders: ", "Digite CLEAN para excluir permanentemente estes arquivos e pastas: ", "Escribe CLEAN para eliminar permanentemente estos archivos y carpetas: "),
    ("cli.cancelled", "Cancelled. No files were removed.", "Cancelado. Nenhum arquivo foi removido.", "Cancelado. No se eliminó ningún archivo."),
    ("cli.inspection_only", "This category is inspection-only: {0}.", "Esta categoria é somente para inspeção: {0}.", "Esta categoría es solo de inspección: {0}."),
    ("cli.choose_project", "Choose an existing project folder: {0}.", "Escolha uma pasta de projeto existente: {0}.", "Elige una carpeta de proyecto existente: {0}."),
    ("cli.unknown", "Unknown command or option: {0}.", "Comando ou opção desconhecido: {0}.", "Comando u opción desconocidos: {0}."),
    ("cli.unknown_category", "Unknown category: {0}. Run sniff categories.", "Categoria desconhecida: {0}. Rode sniff categories.", "Categoría desconocida: {0}. Ejecuta sniff categories."),
    ("cli.category_not_on_linux", "The {0} category exists only in the macOS app; it has no Linux rule.", "A categoria {0} existe só no app macOS; não há regra para Linux.", "La categoría {0} solo existe en la app de macOS; no tiene regla para Linux."),
    ("cli.missing_value", "Missing value for {0}.", "Falta o valor de {0}.", "Falta el valor de {0}."),
    ("cli.bad_language", "Use en, pt, es or system for --language.", "Use en, pt, es ou system em --language.", "Usa en, pt, es o system en --language."),
    ("cli.category_or_path", "Use either --category or --path, not both.", "Use --category ou --path, não os dois.", "Usa --category o --path, no ambos."),
    ("cli.quick_or_worktrees", "Use either --quick or --worktrees, not both.", "Use --quick ou --worktrees, não os dois.", "Usa --quick o --worktrees, no ambos."),
    ("cli.option_only_for", "{0} is only available for: {1}.", "{0} só está disponível para: {1}.", "{0} solo está disponible para: {1}."),
    ("cli.filters_only_list_plan", "Selection filters are only available for list and plan.", "Filtros de seleção só estão disponíveis para list e plan.", "Los filtros de selección solo están disponibles para list y plan."),
    ("cli.config_requires_command", "Configuration changes require the config command.", "Alterações de configuração exigem o comando config.", "Los cambios de configuración requieren el comando config."),
    ("cli.clean_requires_plan", "clean requires --plan. Create a reviewed plan with sniff plan --output first.", "clean exige --plan. Crie antes um plano revisado com sniff plan --output.", "clean requiere --plan. Crea antes un plan revisado con sniff plan --output."),
    ("cli.scan_summary", "{0} items ready for review; {1} estimated.", "{0} itens prontos para revisão; {1} estimados.", "{0} elementos listos para revisión; {1} estimados."),
    ("cli.plan_saved", "Plan saved to {0}. No files were removed.", "Plano salvo em {0}. Nenhum arquivo foi removido.", "Plan guardado en {0}. No se eliminó ningún archivo."),
    ("cli.preview_only", "Preview only. Use --output to save a cleanup plan.", "Somente prévia. Use --output para salvar um plano de limpeza.", "Solo vista previa. Usa --output para guardar un plan de limpieza."),
    ("cli.tag_removed", "removed", "removido", "eliminado"),
    ("cli.tag_partial", "partial", "parcial", "parcial"),
    ("cli.tag_preserved", "preserved", "preservado", "conservado"),
    ("cli.estimated_freed", "Estimated allocation removed: {0}", "Alocação estimada removida: {0}", "Asignación estimada eliminada: {0}"),
    ("cli.free_space_change", "Measured free space change: {0}", "Variação medida do espaço livre: {0}", "Variación medida del espacio libre: {0}"),
    ("cli.free_space_unavailable", "Free space measurement unavailable.", "Medida de espaço livre indisponível.", "Medición del espacio libre no disponible."),
    ("cli.no_history", "No cleanups yet.", "Nenhuma limpeza ainda.", "Todavía no hay limpiezas."),
    ("cli.inspection_only_tag", "inspection only", "somente inspeção", "solo inspección"),
    ("cli.manual_tag", "manual only", "somente manual", "solo manual"),
    ("cli.not_on_linux", "Not available on Linux (macOS app only): {0}", "Indisponível no Linux (somente no app macOS): {0}", "No disponible en Linux (solo en la app de macOS): {0}"),
    ("cli.status_last_scan", "Last scan: {0}", "Última análise: {0}", "Último análisis: {0}"),
    ("cli.never", "not yet", "ainda não aconteceu", "todavía no"),
    ("cli.schedule_off", "Scheduling is off.", "O agendamento está desligado.", "La programación está desactivada."),
    ("cli.schedule_on", "Scheduling is on and the systemd user timer is active.", "O agendamento está ligado e o timer do systemd do usuário está ativo.", "La programación está activada y el temporizador de systemd del usuario está activo."),
    ("cli.schedule_mismatch", "Scheduling setting and systemd registration disagree. Run sniff schedule enable or disable.", "A configuração de agendamento e o registro no systemd divergem. Rode sniff schedule enable ou disable.", "El ajuste de programación y el registro en systemd no coinciden. Ejecuta sniff schedule enable o disable."),
    ("cli.schedule_next", "Next wake: {0}", "Próximo despertar: {0}", "Próximo despertar: {0}"),
    ("cli.review_header", "Cleanup plan (permanent removal):", "Plano de limpeza (remoção permanente):", "Plan de limpieza (eliminación permanente):"),
    ("cli.review_total", "{0} items · {1} estimated", "{0} itens · {1} estimados", "{0} elementos · {1} estimados"),
    // Help
    ("help.tagline", "Cleans what AI agents and dev tools leave behind, with local rules and no model calls.", "Limpa o que agentes de IA e ferramentas de desenvolvimento deixam para trás, com regras locais e sem chamadas a modelos.", "Limpia lo que dejan los agentes de IA y las herramientas de desarrollo, con reglas locales y sin llamadas a modelos."),
    ("help.usage", "USAGE", "USO", "USO"),
    ("help.commands", "COMMANDS", "COMANDOS", "COMANDOS"),
    ("help.options", "OPTIONS", "OPÇÕES", "OPCIONES"),
    ("help.scan", "Scan without removing anything", "Analisa sem remover nada", "Analiza sin eliminar nada"),
    ("help.list", "Show the last scan", "Mostra a última análise", "Muestra el último análisis"),
    ("help.plan", "Select items for a cleanup plan", "Seleciona itens para um plano de limpeza", "Selecciona elementos para un plan de limpieza"),
    ("help.plan_output", "Save the plan to a new private file", "Salva o plano em um novo arquivo privado", "Guarda el plan en un archivo privado nuevo"),
    ("help.clean", "Revalidate and remove a saved plan", "Revalida e remove um plano salvo", "Revalida y elimina un plan guardado"),
    ("help.status", "Summary and scheduler registration", "Resumo e registro do agendador", "Resumen y registro del programador"),
    ("help.history", "Past cleanups", "Limpezas anteriores", "Limpiezas anteriores"),
    ("help.categories", "Categories and Linux paths", "Categorias e caminhos no Linux", "Categorías y rutas en Linux"),
    ("help.config", "Enable or disable a category", "Habilita ou desabilita uma categoria", "Habilita o deshabilita una categoría"),
    ("help.config_paths", "Add project folders or exclusions", "Adiciona pastas de projetos ou exclusões", "Añade carpetas de proyectos o exclusiones"),
    ("help.config_retention", "Days an item must be untouched", "Dias que um item precisa ficar sem alterações", "Días que un elemento debe quedar sin cambios"),
    ("help.schedule", "systemd user timer (off by default)", "Timer do systemd do usuário (desligado por padrão)", "Temporizador de systemd del usuario (desactivado por defecto)"),
    ("help.json", "JSON output on stdout", "Saída JSON no stdout", "Salida JSON en stdout"),
    ("help.language", "Language for this command", "Idioma deste comando", "Idioma de este comando"),
    ("help.help", "Show this help", "Mostra esta ajuda", "Muestra esta ayuda"),
    ("help.version", "Show the version", "Mostra a versão", "Muestra la versión"),
    ("help.expiry", "Plans expire 15 minutes after the scan.", "Planos vencem 15 minutos após a análise.", "Los planes caducan 15 minutos después del análisis."),
    ("help.manual", "Worktrees, npx, logs and builds need explicit enablement and selection; they are never cleaned automatically.", "Worktrees, npx, logs e compilações exigem habilitação e seleção explícitas; nunca são limpos automaticamente.", "Worktrees, npx, registros y compilaciones requieren habilitación y selección explícitas; nunca se limpian automáticamente."),
    // Plugin interface
    ("ui.title", "Sniff", "Sniff", "Sniff"),
    ("ui.tagline", "Sniffs out what agents and dev tools leave behind.", "Fareja o que agentes e ferramentas de desenvolvimento deixam para trás.", "Olfatea lo que dejan los agentes y las herramientas de desarrollo."),
    ("ui.scan_quick", "Scan caches", "Analisar caches", "Analizar cachés"),
    ("ui.scan_full", "Full scan", "Análise completa", "Análisis completo"),
    ("ui.scan_worktrees", "Scan worktrees", "Analisar worktrees", "Analizar worktrees"),
    ("ui.sniffing", "Sniffing…", "Farejando…", "Olfateando…"),
    ("ui.idle_hint", "No scan yet. Scanning never removes files.", "Nenhuma análise ainda. Analisar nunca remove arquivos.", "Todavía no hay análisis. Analizar nunca elimina archivos."),
    ("ui.filter_all", "All", "Todas", "Todas"),
    ("ui.filter_ready", "Ready", "Pode limpar", "Se puede limpiar"),
    ("ui.filter_pending", "Pending", "Com pendências", "Con pendientes"),
    ("ui.filter_in_use", "In use", "Em uso", "En uso"),
    ("ui.filter_preserved", "Preserved", "Preservados", "Conservados"),
    ("ui.search", "Search path or branch", "Buscar caminho ou branch", "Buscar ruta o rama"),
    ("ui.empty", "Nothing here for this filter.", "Nada aqui para este filtro.", "No hay nada con este filtro."),
    ("ui.selected", "{0} selected · {1} estimated", "{0} selecionados · {1} estimados", "{0} seleccionados · {1} estimados"),
    ("ui.review", "Review cleanup", "Revisar limpeza", "Revisar limpieza"),
    ("ui.review_title", "Permanently delete these items?", "Excluir estes itens permanentemente?", "¿Eliminar estos elementos permanentemente?"),
    ("ui.review_body", "Sniff checks each item again before removing it. Changed, excluded or busy items are kept. Deleted files cannot be restored.", "O Sniff confere cada item de novo antes de remover. Itens alterados, excluídos ou em uso são mantidos. Arquivos excluídos não podem ser recuperados.", "Sniff vuelve a comprobar cada elemento antes de eliminarlo. Los elementos cambiados, excluidos u ocupados se conservan. Los archivos eliminados no se pueden recuperar."),
    ("ui.expires", "Plan expires at {0}", "O plano vence às {0}", "El plan caduca a las {0}"),
    ("ui.confirm", "Delete permanently", "Excluir permanentemente", "Eliminar permanentemente"),
    ("ui.cancel", "Cancel", "Cancelar", "Cancelar"),
    ("ui.cleaning", "Revalidating and removing…", "Revalidando e removendo…", "Revalidando y eliminando…"),
    ("ui.result", "Cleanup result", "Resultado da limpeza", "Resultado de la limpieza"),
    ("ui.done", "Done", "Concluir", "Listo"),
    ("ui.exclude", "Always keep this path", "Sempre preservar este caminho", "Conservar siempre esta ruta"),
    ("ui.excluded", "Exclusion saved. Scan again to update the list.", "Exclusão salva. Analise novamente para atualizar a lista.", "Exclusión guardada. Vuelve a analizar para actualizar la lista."),
    ("ui.enable_category", "Enable {0} for manual cleanup", "Habilitar {0} para limpeza manual", "Habilitar {0} para limpieza manual"),
    ("ui.category_disabled", "Category disabled in settings. Enable it to select items.", "Categoria desabilitada nos ajustes. Habilite para selecionar itens.", "Categoría deshabilitada en los ajustes. Habilítala para seleccionar elementos."),
    ("ui.binary_missing", "The sniff command was not found. Install it with script/omarchy_install.sh.", "O comando sniff não foi encontrado. Instale com script/omarchy_install.sh.", "No se encontró el comando sniff. Instálalo con script/omarchy_install.sh."),
    ("ui.error", "Something went wrong: {0}", "Algo deu errado: {0}", "Algo salió mal: {0}"),
    ("ui.keys", "↑↓ move · Space select · Enter details · r rescan · f filter · Esc close", "↑↓ mover · Espaço seleciona · Enter detalhes · r analisa · f filtro · Esc fecha", "↑↓ mover · Espacio selecciona · Enter detalles · r analiza · f filtro · Esc cierra"),
    ("ui.partial_size", "at least {0}", "pelo menos {0}", "al menos {0}"),
    ("ui.last_scan", "Last scan {0}", "Última análise {0}", "Último análisis {0}"),
    ("ui.measures", "Logical {0} · Allocated (estimate) {1}", "Lógico {0} · Alocado (estimativa) {1}", "Lógico {0} · Asignado (estimación) {1}"),
    ("ui.result_summary", "Estimated allocation removed: {0} · Measured free-space change: {1}", "Alocação estimada removida: {0} · Variação medida do espaço livre: {1}", "Asignación estimada eliminada: {0} · Variación medida del espacio libre: {1}"),
    ("ui.history", "History", "Histórico", "Historial"),
    ("ui.settings", "Settings", "Ajustes", "Ajustes"),
];

pub fn lookup(lang: Lang, key: &str) -> Option<&'static str> {
    CATALOG
        .iter()
        .find(|(k, ..)| *k == key)
        .map(|(_, en, pt, es)| match lang {
            Lang::En => *en,
            Lang::Pt => *pt,
            Lang::Es => *es,
        })
}

/// Text for a key without arguments. Unknown keys are shown as-is.
pub fn text(lang: Lang, key: &str) -> String {
    lookup(lang, key).map(str::to_string).unwrap_or_else(|| key.to_string())
}

pub fn render(lang: Lang, m: &Msg) -> String {
    render_depth(lang, m, 0)
}

fn render_depth(lang: Lang, m: &Msg, depth: usize) -> String {
    let template = text(lang, &m.k);
    let args: Vec<String> =
        m.a.iter()
            .map(|a| match a {
                // Arguments that are themselves category keys are translated.
                MsgArg::Text(t) if t.starts_with("category.") => text(lang, t),
                MsgArg::Text(t) => t.clone(),
                MsgArg::Msg(sub) if depth < 4 => render_depth(lang, sub, depth + 1),
                MsgArg::Msg(sub) => sub.k.clone(),
            })
            .collect();
    // Single pass, so placeholders inside arguments stay literal.
    let mut out = String::with_capacity(template.len());
    let mut rest = template.as_str();
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        match after
            .find('}')
            .and_then(|end| after[..end].parse::<usize>().ok().map(|i| (i, end)))
        {
            Some((i, end)) if i < args.len() => {
                out.push_str(&args[i]);
                rest = &after[end + 1..];
            }
            _ => {
                out.push('{');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Binary units with a locale decimal separator: "1.1 GB" / "1,1 GB".
pub fn format_bytes(lang: Lang, n: u64) -> String {
    const UNITS: [&str; 6] = ["B", "KB", "MB", "GB", "TB", "PB"];
    if n < 1024 {
        return format!("{n} B");
    }
    let mut v = n as f64;
    let mut u = 0;
    while v >= 1024.0 && u < UNITS.len() - 1 {
        v /= 1024.0;
        u += 1;
    }
    let s = if v >= 100.0 {
        format!("{v:.0}")
    } else {
        format!("{v:.1}")
    };
    let s = if lang == Lang::En { s } else { s.replace('.', ",") };
    format!("{s} {}", UNITS[u])
}

/// Interface strings for the plugin, rendered in one language.
pub fn ui_strings(lang: Lang) -> serde_json::Map<String, serde_json::Value> {
    CATALOG
        .iter()
        .filter(|(k, ..)| {
            k.starts_with("ui.")
                || k.starts_with("state.")
                || k.starts_with("wtstatus.")
                || k.starts_with("category.")
                || *k == "detail.no_backup"
        })
        .map(|(k, ..)| (k.to_string(), serde_json::Value::String(text(lang, k))))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn placeholders(s: &str) -> Vec<String> {
        let mut v: Vec<String> = (0..6)
            .map(|i| format!("{{{i}}}"))
            .filter(|p| s.contains(p.as_str()))
            .collect();
        v.sort();
        v
    }

    #[test]
    fn catalog_is_complete_and_consistent() {
        let mut keys = HashSet::new();
        for (k, en, pt, es) in CATALOG {
            assert!(keys.insert(*k), "duplicate key {k}");
            assert!(!en.is_empty() && !pt.is_empty() && !es.is_empty(), "{k} empty");
            assert_eq!(placeholders(en), placeholders(pt), "{k} pt placeholders");
            assert_eq!(placeholders(en), placeholders(es), "{k} es placeholders");
        }
        for c in crate::model::Category::ALL {
            assert!(lookup(Lang::En, &c.title_key()).is_some(), "{c:?} title");
        }
    }

    #[test]
    fn every_key_used_in_sources_exists() {
        let dirs = [
            concat!(env!("CARGO_MANIFEST_DIR"), "/src"),
            concat!(env!("CARGO_MANIFEST_DIR"), "/../sniff-cli/src"),
        ];
        for dir in dirs {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let text = std::fs::read_to_string(entry.path()).unwrap();
                for part in text
                    .split("Msg::new(\"")
                    .skip(1)
                    .chain(text.split("text(ctx.lang, \"").skip(1))
                {
                    let key = part.split('"').next().unwrap();
                    assert!(
                        lookup(Lang::En, key).is_some(),
                        "missing key {key} in {:?}",
                        entry.path()
                    );
                }
            }
        }
    }

    #[test]
    fn language_matching() {
        assert_eq!(Lang::from_locales(["pt_BR.UTF-8"]), Lang::Pt);
        assert_eq!(Lang::from_locales(["pt-PT"]), Lang::Pt);
        assert_eq!(Lang::from_locales(["es-MX"]), Lang::Es);
        assert_eq!(Lang::from_locales(["en_GB"]), Lang::En);
        assert_eq!(Lang::from_locales(["ja", "es_AR"]), Lang::Es);
        assert_eq!(Lang::from_locales(["ja"]), Lang::En);
        assert_eq!(Lang::from_locales(Vec::<&str>::new()), Lang::En);
        assert_eq!(Lang::resolve("pt", Some("es")), Lang::Es);
        assert_eq!(Lang::resolve("pt", None), Lang::Pt);
    }

    #[test]
    fn renders_nested_messages_and_paths_verbatim() {
        let tricky = "/home/fixture/árbol/{0}/50%/foo · versão bar (1)";
        let m = Msg::new("exec.partial").nested(Msg::new("removal.changed").arg(tricky));
        let es = render(Lang::Es, &m);
        assert!(es.starts_with("Limpieza parcial."));
        assert!(es.contains(tricky));
        assert_eq!(
            render(Lang::Es, &Msg::new("reason.recent").arg(14)),
            "El elemento cambió en los últimos 14 días y se ha conservado."
        );
        assert_eq!(
            render(Lang::En, &Msg::new("detail.unpublished").arg(2)),
            "Unpublished commits: 2."
        );
        assert_eq!(
            render(Lang::Es, &Msg::new("detail.ignored_count").arg(3)),
            "3 rutas ignoradas por Git."
        );
    }

    #[test]
    fn byte_formatting() {
        assert_eq!(format_bytes(Lang::En, 512), "512 B");
        assert_eq!(format_bytes(Lang::En, 1_181_116_006), "1.1 GB");
        assert_eq!(format_bytes(Lang::Pt, 1_181_116_006), "1,1 GB");
    }
}
