# Sniff — instruções do projeto

Aplicativo macOS nativo, SwiftUI/SwiftPM, sem dependências externas. Nome público e técnico: Sniff. A interface oferece inglês, português e espanhol, com seleção de idioma nos Ajustes.

- Use `./script/build_and_run.sh` para compilar, empacotar e abrir. O botão Run usa esse comando.
- Testes: `./script/test.sh`; integração launchd: `./script/test_scheduler.sh`.
- Nunca executar uma limpeza real para demonstrar ou testar o app. Usar fixtures em diretórios temporários exclusivos. Limpeza real depende da seleção e confirmação do usuário no app ou autorização delimitada.
- Preserve sessões, fontes, configurações, credenciais, bancos, volumes, runtimes principais e worktrees por padrão.
- Mantenha análise, plano revisável, revalidação e remoção separados. Sem comandos shell construídos com caminhos do usuário.
- Não seguir symlinks para fora das raízes reconhecidas. Manter a remoção baseada em descritores e manifesto.
- Não encerrar aplicações, agentes ou builds. Não pedir root/sudo ou Full Disk Access indiscriminadamente.
- Tratar alocação APFS como estimativa e mostrar variação líquida medida separadamente.
- Documentar limitações reais. UI com toggle não comprova agendamento; verificar registro e despertar do sistema.
- Manter views, modelos, scanner, políticas, executor, persistência e agendamento em arquivos separados.
- Respeitar aparência semântica do sistema, acessibilidade e Reduce Motion.
