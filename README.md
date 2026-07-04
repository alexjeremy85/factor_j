# Factor J

Transcrição e diarização de áudio **100% local** para macOS (Apple Silicon).
Identifica "quem falou o quê e quando" sem nenhuma conexão de rede em runtime.

- **ASR:** Whisper large-v3-turbo via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML/ANE)
- **Diarização:** Pyannote segmentation + WeSpeaker via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML/ANE)
- **UI:** SwiftUI nativo · **Banco:** SQLite (GRDB) com busca full-text FTS5
- **Privacidade:** sem analytics, sem telemetria, sem chamadas de rede em uso — os modelos são baixados uma única vez pelo assistente do próprio app (ou via script)

Especificação completa: [docs/especificacao.md](docs/especificacao.md).

## Instalação (para quem só quer usar)

1. Baixe o `FactorJ-x.y.z.dmg` mais recente em [Releases](https://github.com/alexjeremy85/factor_j/releases)
2. Abra o DMG e arraste **Factor J** para **Aplicativos**
3. Na primeira abertura: **botão direito no app → Abrir → Abrir** (o app não é notarizado pela Apple; o código é aberto e auditável neste repositório)
4. Siga o assistente para baixar os modelos de IA (~1,7 GB, uma única vez)

Requisitos: Mac com Apple Silicon (M1 ou superior) e macOS 14.4+.

**Seus dados:** tudo fica em `~/Library/Application Support/FactorJ/` e permanece até você excluir. Para backup, copie essa pasta (Ajustes → Geral mostra o caminho com um clique).

**Gravação de reuniões:** ⌥⌘R (atalho global) ou pela barra de menus — captura microfone + áudio do sistema (Teams/Zoom/Meet) e transcreve sozinho ao encerrar.

## Status

| Fase | Escopo | Situação |
|---|---|---|
| **Fase 1 — Núcleo batch** | Importação, pipeline transcrição+diarização+alinhamento, tela de transcrição, exportações, busca | **Implementada** (validação de desempenho na máquina de referência pendente) |
| Fase 2 — Gravador ao vivo | Captura mic + sistema, transcrição provisória, consolidação | Não iniciada |
| Fase 3 — Polimento | Backup .zip, atalho global, DMG assinado/notarizado | Não iniciada |

## Requisitos

- macOS 14.4+ em Apple Silicon (referência: MacBook Air M2, 16 GB)
- Swift 5.10+ (Command Line Tools bastam; Xcode completo é opcional)
- ~2 GB de disco para os modelos

## Como rodar

```bash
# 1. Rodar em modo dev (no primeiro uso, o app oferece baixar os modelos ~1,7 GB)
swift run FactorJ

# 2. (Opcional) Gerar o .app
./scripts/bundle.sh                  # produz dist/FactorJ.app

# Alternativa por terminal para os modelos:
./scripts/fetch_models.sh            # --with-base inclui o modelo rápido
```

Os dados ficam em `~/Library/Application Support/FactorJ/`
(`escriba.sqlite`, `Audio/`, `Models/`).

## Testes

```bash
./scripts/test.sh      # ou `swift test` se você tiver o Xcode completo
```

Cobrem o alinhador transcrição×diarização, exportadores, banco (incl. FTS5 e
cascatas) e conversão de áudio. Os testes não dependem dos modelos de ML.
O script injeta os caminhos do framework Swift Testing, necessários quando só
os Command Line Tools estão instalados.

## Arquitetura

```
Sources/
  FactorJCore/          # biblioteca testável, sem UI
    Models/             # Recording, Speaker, Segment, Marker (GRDB)
    Database/           # migrations, CRUD, busca FTS5
    Storage/            # layout de disco (Application Support)
    Audio/              # conversão AVFoundation → WAV 16 kHz mono (streaming)
    Pipeline/           # motores (WhisperKit/FluidAudio), alinhador, fila
    Export/             # .txt .srt .vtt .json .md
  FactorJ/              # app SwiftUI (sidebar, transcrição, player, ajustes)
scripts/
  fetch_models.sh       # download único dos modelos + SHA256SUMS
  bundle.sh             # empacota dist/FactorJ.app
  make_dmg.sh           # gera o DMG de distribuição
```

Decisões técnicas relevantes:

- **Janelas de ~20 min com corte em silêncio:** arquivos de até 4 h processam
  com memória estável; a mesma instância do diarizador atravessa as janelas
  (offset `atTime`), preservando a identidade dos falantes.
- **Alinhamento por palavra:** com word timestamps do Whisper, um segmento que
  atravessa troca de falante é dividido no ponto certo; sobreposição de falas
  é marcada (`isOverlap`).
- **Offline verificável:** WhisperKit configurado com `download: false` e
  tokenizer local; FluidAudio carrega `.mlmodelc` do disco. O critério de
  aceite é rodar com Wi-Fi desligado e Little Snitch sem nenhuma tentativa
  de conexão.
- **Crash-safe:** gravações interrompidas em `processing` voltam como
  `failed` reprocessável na abertura seguinte.
