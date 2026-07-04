# Especificação Técnica — App de Transcrição e Diarização Local para macOS

**Codinome do projeto:** Escriba
**Versão do documento:** 1.0
**Data:** 03/07/2026
**Solicitante:** Alex Guimarães
**Público deste documento:** Desenvolvedor(a) responsável pela implementação

---

## 1. Visão Geral

Aplicativo nativo para macOS que transcreve e diariza áudio (identifica "quem falou o quê e quando") **100% localmente**, sem qualquer conexão de rede em tempo de execução, aproveitando ao máximo o hardware Apple Silicon (GPU via Metal/MLX e Neural Engine via CoreML).

O app opera em dois modos:

1. **Modo Arquivo (batch):** o usuário importa um arquivo de áudio/vídeo e recebe a transcrição diarizada.
2. **Modo Gravador (ao vivo):** o app grava reuniões (microfone + áudio do sistema), exibindo transcrição e rótulos de falantes provisórios em tempo real, com consolidação final offline ao encerrar a gravação.

### 1.1 Princípios inegociáveis

- **Offline absoluto em runtime:** nenhuma chamada de rede durante o uso. Os modelos de ML devem ser **embarcados no bundle do app** (ou instalados junto com ele em um passo único de setup). O app deve funcionar integralmente com o Wi-Fi desligado. Recomenda-se inclusive configurar o sandbox/entitlements **sem** `com.apple.security.network.client`, tornando a ausência de rede verificável.
- **Privacidade:** nenhum dado de áudio, transcrição ou telemetria sai da máquina. Sem analytics, sem crash reporting remoto.
- **Apple Silicon first:** todo o pipeline de inferência deve rodar em GPU (Metal) e/ou Neural Engine (ANE). CPU apenas como fallback ou para etapas leves (clustering, I/O).

### 1.2 Hardware e ambiente alvo

| Item | Especificação |
|---|---|
| Máquina de referência | MacBook Air M2 (2022), 8-core CPU, 10-core GPU, 16 GB RAM unificada, SSD 256 GB |
| macOS mínimo | macOS 14.4+ (requisito do Core Audio Taps; ver §5.2) |
| Idioma principal do áudio | Português (pt-BR) — obrigatório |
| Idiomas secundários | Inglês e espanhol desejáveis |
| Orçamento de disco | Modelos embarcados ≤ 4 GB no total |
| Orçamento de RAM em uso | Pico ≤ 6 GB durante processamento (a máquina tem 16 GB compartilhados com o resto do sistema) |

---

## 2. Stack Tecnológica

| Camada | Tecnologia | Justificativa |
|---|---|---|
| Linguagem / UI | Swift 5.10+ / SwiftUI | App nativo, distribuível, menor consumo que Electron/Python |
| ASR (transcrição) | Whisper `large-v3-turbo` via **WhisperKit** (CoreML) **ou** MLX Swift | Melhor qualidade comprovada em pt-BR; turbo tem ótimo custo-benefício no M2 |
| ASR streaming (modo gravador) | Mesmo Whisper turbo em janelas/chunks (ver §6.3) | Modelos streaming nativos (Parakeet EOU) são somente inglês |
| Diarização | **FluidAudio** (Swift/CoreML): Pyannote segmentation-3.0 + embeddings de falante (CAM++/WeSpeaker), pipelines offline e streaming | Mesma base do Senko; roda no ANE; é a referência de velocidade em Apple Silicon |
| VAD | Silero VAD (via FluidAudio) | Filtra silêncio antes do ASR; barato o suficiente para rodar contínuo |
| Captura de áudio do sistema | Core Audio Taps (macOS 14.4+) com ScreenCaptureKit como alternativa | Capturar Teams/Zoom/Meet sem drivers virtuais de terceiros |
| Persistência | SQLite (GRDB) ou Core Data — decisão do desenvolvedor | Metadados, transcrições, segmentos, falantes |
| Áudio bruto | Arquivos `.caf`/`.m4a` no diretório de dados do app | — |
| Empacotamento | `.app` assinado (Developer ID) + notarização; distribuição por DMG | Uso pessoal, fora da App Store (evita restrições de sandbox na captura de áudio) |

**Dependências proibidas:** qualquer SDK de rede/analytics; qualquer runtime Python embutido; qualquer API de nuvem.

---

## 3. Modelos de ML (embarcados)

| Função | Modelo | Formato | Tamanho aprox. |
|---|---|---|---|
| Transcrição | Whisper large-v3-turbo | CoreML (WhisperKit) ou MLX 4-bit | ~1,5–2 GB |
| Transcrição rápida (opcional, preview ao vivo) | Whisper small/base multilíngue | CoreML/MLX | ~200–500 MB |
| Segmentação de fala | Pyannote segmentation-3.0 | CoreML | ~6 MB |
| Embeddings de falante | CAM++ ou WeSpeaker ResNet34 | CoreML | ~15–30 MB |
| VAD | Silero VAD v5 | CoreML | ~2 MB |

Requisitos:

- Os modelos são **parte do instalador**. Nenhum download em runtime.
- Verificação de integridade (checksum) dos modelos no primeiro launch.
- Warm-up dos modelos em background ao abrir o app, para a primeira inferência não travar a UI.

---

## 4. Modo Arquivo (batch)

### 4.1 Fluxo do usuário

1. Usuário arrasta um arquivo para a janela (ou usa botão "Importar" / menu Arquivo / atalho ⌘O).
2. App exibe card do arquivo com duração, formato e tamanho.
3. Usuário escolhe opções (com defaults inteligentes):
   - Idioma: auto-detect (default) ou fixo (pt, en, es)
   - Diarização: ligada (default) / desligada
   - Número de falantes: auto (default) ou fixo (2–10)
4. Barra de progresso com etapas nomeadas ("Convertendo áudio…", "Transcrevendo…", "Identificando falantes…", "Alinhando…").
5. Resultado abre na tela de Transcrição (ver §7.3).

### 4.2 Requisitos funcionais

- **RF-A1:** Aceitar qualquer formato legível pelo AVFoundation: `.m4a`, `.mp3`, `.wav`, `.aac`, `.caf`, `.mp4`, `.mov` (extrair trilha de áudio de vídeo).
- **RF-A2:** Converter internamente para WAV 16 kHz mono (pipeline padrão dos modelos).
- **RF-A3:** Suportar fila de processamento: múltiplos arquivos importados processam em sequência, com fila visível e cancelável.
- **RF-A4:** Processamento cancelável a qualquer momento sem corromper o banco.
- **RF-A5:** Alinhamento transcrição × diarização por sobreposição temporal de segmentos, atribuindo cada trecho de texto ao falante com maior interseção; trechos com sobreposição de falas devem ser marcados (flag `overlap`).
- **RF-A6:** Arquivos longos (até 4 h) devem processar por chunks com uso de memória estável (streaming de leitura, nunca carregar o áudio inteiro em RAM).

### 4.3 Metas de desempenho (M2, 16 GB)

| Cenário | Meta |
|---|---|
| Transcrição pura, áudio de 10 min | ≤ 60 s |
| Transcrição + diarização, reunião de 60 min | ≤ 8 min no total |
| Diarização isolada, 60 min de áudio | ≤ 60 s |
| Uso de RAM no pico (arquivo de 60 min) | ≤ 6 GB |

Essas metas são compatíveis com os benchmarks públicos de WhisperKit/MLX e FluidAudio/Senko em Apple Silicon; devem ser validadas na Fase 1 (§9).

---

## 5. Modo Gravador (reunião ao vivo)

### 5.1 Fluxo do usuário

1. Botão "Gravar reunião" na tela inicial (e atalho global configurável).
2. Seletor de fontes: **Microfone**, **Áudio do sistema**, ou **Ambos** (default: Ambos).
3. Durante a gravação:
   - Timer + indicador de nível de áudio por fonte.
   - Transcrição ao vivo aparecendo em blocos, com rótulo provisório de falante (`Falante A`, `Falante B`…) e marcação visual de "provisório".
   - Botões: Pausar/Retomar, Marcar momento (flag manual com timestamp), Encerrar.
4. Ao encerrar: app roda automaticamente o **passe de consolidação offline** (re-diarização + re-transcrição de qualidade sobre o áudio completo) e substitui o resultado provisório pelo final. Progresso visível; o usuário pode navegar pelo app enquanto isso.

### 5.2 Captura de áudio

- **RF-G1:** Capturar microfone via AVAudioEngine.
- **RF-G2:** Capturar áudio do sistema via **Core Audio Process Taps** (macOS 14.4+). Não usar drivers virtuais (BlackHole etc.) como solução principal — no máximo documentar como fallback manual.
- **RF-G3:** Gravar as duas fontes em **canais separados** (mic = canal L, sistema = canal R, ou dois arquivos sincronizados). Isso é insumo valioso para diarização: fala no canal do mic é, por definição, o usuário local.
- **RF-G4:** Persistir o áudio em disco de forma incremental (a cada ~5 s), de modo que um crash ou queda de energia nunca perca mais que 5 s de gravação.
- **RF-G5:** Detectar e exibir claramente quando a permissão de captura do sistema não foi concedida, com botão que abre o painel certo em Ajustes do Sistema.

### 5.3 Pipeline ao vivo (dois passes)

**Passe 1 — tempo real (provisório):**

- VAD contínuo (Silero) filtra silêncio.
- Diarização streaming da FluidAudio gera rótulos provisórios de falante por segmento.
- Transcrição em chunks: janelas de ~8–15 s de fala acumulada são enviadas ao Whisper (modelo turbo, ou o modelo small se a latência com o turbo passar de ~5 s por chunk na máquina de referência — decidir com benchmark na Fase 2).
- Latência alvo do texto na tela: **≤ 5 s** após o fim da fala.
- É aceitável (e esperado) que o texto provisório contenha erros e que rótulos de falante mudem.

**Passe 2 — consolidação (ao encerrar):**

- Re-executa o pipeline batch completo (§4) sobre o áudio integral gravado.
- Reconcilia rótulos: falantes provisórios são mapeados para os falantes finais; marcações manuais ("Marcar momento") são preservadas por timestamp.
- O resultado final substitui o provisório e é o único persistido como transcrição oficial (o provisório pode ser descartado).

### 5.4 Restrições e não-objetivos do modo ao vivo

- **Não** é objetivo ter legenda instantânea palavra a palavra; o alvo é acompanhamento da reunião com ~5 s de atraso.
- **Não** haverá identificação nominal automática de falantes na v1 (ver §8, Backlog: enrollment de voz).
- Overlap de falas será tratado com melhor esforço no passe 2; no passe 1 pode ser atribuído a um único falante.

---

## 6. Dados e Persistência

### 6.1 Modelo de dados (mínimo)

```
Recording
  id, title, createdAt, duration, sourceType (file|live),
  audioPath, status (queued|processing|live|consolidating|done|failed),
  language, notes

Speaker
  id, recordingId, label (SPEAKER_00…), displayName (editável),
  colorIndex, embeddingRef (opcional, para futuro enrollment)

Segment
  id, recordingId, speakerId, startMs, endMs, text,
  confidence, isOverlap, isProvisional

Marker
  id, recordingId, timestampMs, note
```

### 6.2 Regras

- **RF-D1:** Tudo em disco local, dentro de `~/Library/Application Support/<app>/` (ou pasta escolhida pelo usuário em Ajustes).
- **RF-D2:** Renomear falante (`SPEAKER_00` → "Fulano") atualiza todas as visualizações e exportações daquela gravação.
- **RF-D3:** Busca full-text no texto das transcrições (FTS5 do SQLite), com resultados agrupados por gravação e clique levando ao timestamp.
- **RF-D4:** Exclusão de gravação remove áudio + dados, com confirmação.
- **RF-D5:** Backup/portabilidade: exportar e importar uma gravação completa como pacote único (`.zip` com áudio + JSON).

---

## 7. Interface (UI/UX)

### 7.1 Estrutura geral

Janela única estilo apps nativos modernos (sidebar + conteúdo):

- **Sidebar:** lista de gravações (busca, filtro por data/tipo), botão "+ Nova" (Importar arquivo | Gravar reunião).
- **Área principal:** tela da gravação selecionada.
- Suporte a modo claro/escuro do sistema. Texto em pt-BR.

### 7.2 Tela inicial (nenhuma gravação selecionada)

- Dois botões grandes: "Importar arquivo" e "Gravar reunião".
- Zona de drag-and-drop.
- Lista das 5 gravações recentes.

### 7.3 Tela de Transcrição (o coração do app)

- **Player de áudio** fixo no topo: play/pause, velocidade (0.5×–2×), scrubber.
- **Timeline de falantes:** faixa horizontal colorida sob o scrubber mostrando quem fala em cada trecho (uma cor por falante). Clique na timeline navega o áudio.
- **Corpo da transcrição:** blocos por turno de fala — avatar/cor do falante, nome (clicável para renomear), timestamp (clicável: toca o áudio a partir dali), texto.
- **Sincronia bidirecional:** durante o playback, o bloco atual é destacado e a lista rola sozinha (com toggle para desativar o auto-scroll).
- **Edição de texto:** duplo clique em um bloco permite corrigir a transcrição manualmente; alteração marcada como editada.
- **Reatribuição de falante:** menu de contexto no bloco → "Atribuir a…" (corrige erros de diarização).
- **Mesclar falantes:** em Ajustes da gravação, unir dois falantes detectados em um só (caso a mesma pessoa tenha sido dividida).

### 7.4 Tela de Gravação ao vivo

- Conforme §5.1: timer, VU meters por fonte, feed de transcrição provisória, botões Pausar/Marcar/Encerrar.
- Banner discreto durante a consolidação pós-gravação, com progresso.

### 7.5 Exportação

Menu "Exportar" em toda gravação concluída:

| Formato | Conteúdo |
|---|---|
| `.txt` | `Nome do falante: texto` por turno (formato do scribe) |
| `.srt` | Legendas com `[Nome]` prefixando o texto (compatível DaVinci Resolve/CapCut) |
| `.vtt` | Idem, para web |
| `.json` | Estrutura completa: segments, speakers, timestamps ms, confidence |
| `.md` | Documento formatado com título, data, participantes e transcrição — pronto para Obsidian |

- **RF-E1:** Exportação usa `displayName` dos falantes (renomeados).
- **RF-E2:** Opção "Copiar transcrição" para o clipboard em texto puro.

### 7.6 Ajustes do app

- Pasta de armazenamento.
- Modelo de transcrição (turbo = qualidade | small = velocidade) e idioma default.
- Atalho global para iniciar gravação.
- Comportamento pós-gravação (consolidar automaticamente ou perguntar).
- Botão "Verificar integridade dos modelos".

---

## 8. Backlog (fora do escopo da v1, não implementar agora)

- **Enrollment de voz:** cadastrar a voz de pessoas frequentes (Fulano, Beltrano…) para identificação nominal automática via embeddings.
- Sumarização local da reunião com LLM via MLX (ex.: Llama/Qwen quantizado) — o design do banco já deve permitir anexar um campo `summary` por gravação.
- Menu bar app / gravação com um clique na barra de menus.
- Detecção automática de início de reunião (app de call abriu → sugerir gravar).

---

## 9. Fases de Entrega

**Fase 1 — Núcleo batch (MVP utilizável)**
Importação de arquivo, pipeline completo transcrição + diarização + alinhamento, tela de Transcrição (player, timeline, blocos, renomear falante), exportação .txt/.srt/.json, persistência e busca.
*Critério de saída: as metas de desempenho da §4.3 medidas e atingidas na máquina de referência.*

**Fase 2 — Gravador**
Captura mic + sistema (canais separados), gravação incremental à prova de crash, pipeline ao vivo provisório, passe de consolidação, tela de gravação.
*Critério de saída: gravar uma reunião real de 30 min no Teams com o resultado final correto e latência provisória ≤ 5 s.*

**Fase 3 — Polimento**
Edição de texto, reatribuição/mesclagem de falantes, exportação .md/.vtt, pacote de backup, ajustes, atalho global, empacotamento DMG assinado e notarizado.

Cada fase entrega um app funcional. Não iniciar a fase seguinte sem os critérios de saída aprovados pelo solicitante.

---

## 10. Critérios de Aceite Globais

1. **Offline verificável:** com Wi-Fi desligado e Little Snitch (ou equivalente) monitorando, o app executa todos os fluxos sem nenhuma tentativa de conexão.
2. **Desempenho:** metas da §4.3 atingidas na máquina de referência, medidas com áudios reais fornecidos pelo solicitante (reuniões em pt-BR com 2–5 falantes).
3. **Qualidade de diarização:** em áudio limpo de reunião com 2–4 falantes, os turnos exibidos correspondem ao falante correto na grande maioria dos casos; erros são corrigíveis pela UI (reatribuir/mesclar).
4. **Qualidade de transcrição:** equivalente ao Whisper large-v3-turbo rodado via linha de comando sobre o mesmo arquivo (mesmo modelo = mesma qualidade; a comparação é o teste).
5. **Robustez:** matar o app durante gravação ao vivo perde no máximo 5 s de áudio; matar durante processamento batch deixa o item como `failed` e reprocessável.
6. **Sem degradação da máquina:** durante gravação ao vivo de 1 h, o app não deve aquecer/derrubar o sistema a ponto de afetar a call (monitorar com powermetrics; alvo: pipeline ao vivo usando fração do ANE/GPU, não saturação).

## 11. Riscos Conhecidos e Mitigações

| Risco | Impacto | Mitigação |
|---|---|---|
| Latência do Whisper turbo em chunks ao vivo acima de 5 s no M2 | Preview lento | Usar modelo small no passe 1 (a qualidade final vem do passe 2) |
| Core Audio Taps exige macOS ≥ 14.4 e permissões que confundem o usuário | Fricção no primeiro uso | Onboarding guiado de permissões com deep-links para Ajustes |
| Diarização streaming trocar rótulos no meio da reunião | Confusão visual | Comunicar "provisório" na UI; consolidação final resolve |
| Vozes muito similares agrupadas como um falante | Erro de diarização | Ferramentas de correção manual (reatribuir/mesclar/dividir) |
| RAM: turbo + diarização + app de call simultâneos em 16 GB | Pressão de memória | Passe 1 com modelo small é o default quando há gravação ativa; medir com Instruments |
| Modelos embarcados incham o instalador (~2–4 GB) | Download/instalação grande | Aceitável (requisito offline); documentar no DMG |
