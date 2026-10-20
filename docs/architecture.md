# Arquitetura

- `Sniff`: SwiftUI, cenas principal/Ajustes/barra de menus. `AppStore` mantém o estado observável no MainActor; scanner e executor trabalham com prioridade utility fora da UI. AppKit fica restrito à ativação, Finder, escolha de pastas e ao item nativo da barra de menus.
- `SniffCore`: modelos Codable/Sendable, catálogo de regras, inventário de processos, scanner, políticas, remoção, persistência e política de agendamento. Sem dependências externas.
- `SniffIdentity`: cachorro vetorial em Canvas. Cabeça e cauda se movem somente durante uma operação real; Reduce Motion mantém a pose estática. Sem porcentagens artificiais.
- `SniffIcon`: renderiza o mesmo vetor em PNG; o script monta o ICNS nas resoluções nativas.
- `SniffScheduler`: entrada CLI para testes do mesmo runner usado pelo app em segundo plano.

## Agendamento nativo

O bundle inclui `Contents/Library/LaunchAgents/app.sniff.scheduler.plist`, com `BundleProgram=Contents/MacOS/Sniff` e argumento `--scheduled`. `SMAppService.agent(plistName:)` registra/remove o serviço do usuário. O processo executa uma vez e sai; `StartInterval=900` verifica se chegou a hora. Sem root, sudo, daemon de sistema ou serviço externo.

Preferências controlam frequência, modo e próxima execução. A análise agendada cobre caches conhecidos. Builds ativos ou inventário inconclusivo adiam a execução por uma hora. Worktrees, Docker e projetos entram na análise manual. O monitor compara metadados das raízes a cada seis horas, sem calcular tamanhos recursivos. Isso sinaliza mudança, não quantidade de bytes acumulados.

O Mac precisa estar acordado e o usuário conectado. Não se promete execução no instante exato durante sono/logout. O app precisa continuar no caminho registrado; após movê-lo, desligue e religue o agendamento. Registro real e notificações são permissões diferentes. O app mostra registros e resultados mesmo sem notificações.

## Persistência e concorrência

`~/Library/Application Support/Sniff/state.json` guarda preferências, último inventário, último despertar e até 30 resultados. Pasta 0700, arquivo 0600, gravação atômica. Nenhum conteúdo de arquivos, credencial ou texto de sessão é copiado para o inventário. `flock` impede sobreposição entre análise, limpeza e serviço agendado. Cada comando usa argumentos separados e um ambiente restrito; nenhum caminho do usuário é interpolado em shell.

## Medição

`lstat` registra dispositivo, inode, tipo, tempos, links, tamanho lógico e blocos alocados. Hardlinks são deduplicados dentro de cada item. APFS pode compartilhar blocos entre itens, snapshots e outros arquivos: o tamanho alocado é uma estimativa, não um ganho garantido. O histórico mede espaço livre antes/depois e mostra a variação líquida, que inclui atividade concorrente no volume.

Worktrees têm medição limitada a 0,18 s / 3.000 entradas por item. Valores incompletos aparecem com **≥** e motivo explícito. A descoberta de projetos se limita a cinco níveis / 7.000 pastas. Não há varredura constante do disco inteiro.

## Fontes primárias consultadas

- [SMAppService — Apple](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Helpers em bundles — Apple](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [CodeSignCloneManager — Chromium](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/mac/code_sign_clone_manager.h)
- [Implementação dos clones — Chromium](https://chromium.googlesource.com/chromium/src/+/lkgr/chrome/browser/mac/code_sign_clone_manager.mm)

## Logo na barra de menus — 0.1.1

A barra usa um `NSStatusItem` mantido pelo AppDelegate, independente da janela principal. O cachorro tem desenho próprio para 30 × 18 pt e imagem template monocromática, acompanhando a aparência do macOS.

Durante análise e limpeza, um timer no run loop comum alterna 24 quadros a 16 fps. O focinho fareja e o rabo gira em torno da base. O timer é invalidado ao ficar ocioso e não roda em repouso. A opção Reduzir Movimento mantém o desenho estático e preserva o texto acessível de atividade. O menu continua oferecendo abrir o app, analisar e acessar Ajustes.

O estado manual vem da observação de `AppStore.busy/canCancel`. O helper agendado envia notificações locais de início/fim ao app aberto, contendo somente PID e fase; elas só alteram a apresentação e não autorizam remoções. A existência do processo é verificada para evitar ícone ativo após um encerramento inesperado do helper. Com o aplicativo encerrado, o helper permanece sem interface, como antes.

Validação específica: `./script/build_and_run.sh --validate-menu-bar` (somente DEBUG) usa o executor real em 12 diretórios descartáveis de `/private/tmp`, sem mudar histórico ou preferências. Produz `work/menu-bar-validation.json`, com contagem de quadros exibidos, presença da janela do item nativo e parada do timer. A prévia ampliada usa o mesmo renderer e pode ser exportada com `.build/debug/SniffIcon --menu-bar-preview outputs/menu-bar-dog.gif`.

[Personalização de NSStatusItem.button — Apple](https://developer.apple.com/documentation/appkit/nsstatusitem/button)
## Idiomas

Os catálogos `en.lproj`, `pt.lproj` e `es.lproj` ficam no bundle de recursos do SniffCore, incluído no aplicativo pelo script de build. O app e o helper usam a mesma preferência `interfaceLanguage` no domínio `app.sniff.mac`. Essa preferência não altera o JSON das análises nem as permissões de limpeza.

As views recebem o locale escolhido e são atualizadas ao trocar o idioma. Textos próprios, acessibilidade, avisos e formatação usam o mesmo catálogo. Os menus padrão do AppKit são atualizados separadamente. Diálogos e mensagens fornecidos pelo sistema ou por ferramentas externas podem acompanhar o idioma do macOS ou da ferramenta.

Os registros de análise mantêm as mensagens originais. A apresentação traduz mensagens conhecidas e seus campos, incluindo os registros anteriores a esta versão. Capturas de caminhos, identificadores e saída de ferramentas são preservadas. Novas mensagens persistidas com parâmetros devem ser incluídas em `LegacyTemplates.json`; as traduções devem manter os mesmos placeholders numerados. Os testes conferem os três catálogos, a preferência, a formatação e a preservação de caminhos com caracteres especiais.
