# Factor J — notas para desenvolvimento

App macOS de transcrição + diarização 100% offline. Especificação completa e
critérios de aceite: `docs/especificacao.md`. Leia antes de mudar comportamento.

## Comandos

```bash
swift build            # build debug (CLT bastam, não precisa de Xcode)
./scripts/test.sh      # testes (usa Swift Testing; injeta flags p/ CLT sem Xcode)
swift run FactorJ      # roda o app
./scripts/bundle.sh    # gera dist/FactorJ.app (assinatura ad-hoc)
./scripts/fetch_models.sh  # instala modelos em ~/Library/Application Support/FactorJ/Models
```

## Regras do projeto

- **Nenhuma chamada de rede durante o uso.** Rede só no assistente de setup de
  modelos (`ModelDownloader`) e em `scripts/fetch_models.sh`.
  WhisperKit sempre com `download: false`; FluidAudio sempre via
  `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)`.
- **Sem runtime Python, sem SDKs de analytics/crash reporting.**
- Alvo: MacBook Air M2 16 GB / macOS 14.4+. Pico de RAM ≤ 6 GB no batch.
- UI em pt-BR. Código/identificadores em inglês, comentários em pt-BR.
- **Nunca usar nomes próprios reais** em placeholders, exemplos, testes ou
  docs — sempre genéricos (Fulano, Beltrano). Repo é público.
- `FactorJCore` não importa SwiftUI/AppKit (exceto AVFoundation/CoreML) e todo
  comportamento novo do core precisa de teste.
- Fase 2 (gravador ao vivo) ainda não começou — não implementar sem pedido
  explícito; critérios de saída por fase estão na §9 da especificação.
