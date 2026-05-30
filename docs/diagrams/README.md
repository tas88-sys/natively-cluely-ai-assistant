# Natively — Architecture Diagrams

Rendered, code-verified diagrams of how Natively works. Full prose in
**[../../ARCHITECTURE.md](../../ARCHITECTURE.md)**; audio triage in
**[../runbook/AUDIO_TROUBLESHOOTING.md](../runbook/AUDIO_TROUBLESHOOTING.md)**.

Each diagram below is **rendered inline** — GitHub and VS Code render `mermaid` code blocks
automatically. The matching `*.mmd` source files are next to this README so they can be edited or
exported independently.

## Rendering to SVG/PNG

The diagrams render natively in GitHub/VS Code (install the *Markdown Preview Mermaid Support* extension
in VS Code if needed). To export image files, use the helper scripts (they pull `mermaid-cli` via `npx`,
no global install):

```bash
# macOS / Linux
bash docs/diagrams/render.sh                 # -> docs/diagrams/rendered/*.svg
FORMAT=png THEME=dark bash docs/diagrams/render.sh
```
```powershell
# Windows
pwsh docs/diagrams/render.ps1                 # -> docs/diagrams/rendered/*.svg
pwsh docs/diagrams/render.ps1 -Format png -Theme dark
```

| # | Diagram | Source |
|---|---|---|
| 1 | System architecture | [`01-system-architecture.mmd`](01-system-architecture.mmd) |
| 2 | Dual-channel audio + STT | [`02-audio-stt-pipeline.mmd`](02-audio-stt-pipeline.mmd) |
| 3 | STT resilience / reconnect | [`03-stt-resilience.mmd`](03-stt-resilience.mmd) |
| 4 | Screenshot / vision pipeline | [`04-vision-pipeline.mmd`](04-vision-pipeline.mmd) |
| 5 | Live intelligence pipeline | [`05-intelligence-pipeline.mmd`](05-intelligence-pipeline.mmd) |
| 6 | Intent classifier (3-tier) | [`06-intent-classifier-tiers.mmd`](06-intent-classifier-tiers.mmd) |
| 7 | Planner decision tree | [`07-planner-decision-tree.mmd`](07-planner-decision-tree.mmd) |
| 8 | RAG / persistence lifecycle | [`08-rag-persistence.mmd`](08-rag-persistence.mmd) |
| 9 | Sequence: live question | [`09-seq-live-question.mmd`](09-seq-live-question.mmd) |
| 10 | Sequence: screenshot | [`10-seq-screenshot.mmd`](10-seq-screenshot.mmd) |
| 11 | Run this repo as-is | [`11-run-as-is.mmd`](11-run-as-is.mmd) |
| 12 | Operator: audio-silent triage | [`12-audio-silent-triage.mmd`](12-audio-silent-triage.mmd) |

---

## 1. System architecture

```mermaid
flowchart TB
    subgraph User["Your machine"]
        subgraph Main["Electron MAIN process (Node) - electron/main.ts (~5100 lines)"]
            WH["WindowHelper (launcher + overlay)"]
            HELPERS["Settings / ModelSelector / Cropper helpers"]
            IPC["ipcHandlers.ts (renderer<->main bridge)"]
            SH["ScreenshotHelper (desktopCapturer)"]
            PH["ProcessingHelper (vision orchestration)"]
            IM["IntelligenceManager / IntelligenceEngine"]
            ST["SessionTracker (rolling context)"]
            AUD["Audio layer (System + Mic capture, STT)"]
            RAG["RAGManager + DatabaseManager"]
            CM["CredentialsManager (encrypted keys)"]
            MODES["ModesManager (personas)"]
        end
        subgraph Rend["Renderer windows (React + Vite)"]
            OV["Overlay (always-on-top, click-through)"]
            LA["Launcher / Dashboard"]
            SET["Settings"]
        end
        subgraph Native["Rust native module (.node, NAPI-RS)"]
            SAC["SystemAudioCapture - mac: CoreAudio+SCK / win: WASAPI loopback"]
            MIC["MicrophoneCapture (CPAL)"]
            VAD["Silence + WebRTC VAD"]
            HW["HardwareID / license / stealth"]
        end
        DB[("SQLite + sqlite-vec - natively.db")]
        FS[("screenshots/*.png - temp, <=5")]
    end
    subgraph Cloud["External services (BYO key)"]
        STT["STT providers"]
        LLM["LLM providers"]
    end

    Rend <-->|IPC| IPC
    IPC --- WH & SH & PH & IM & AUD & RAG & MODES & CM
    AUD --> Native
    Native -->|PCM frames| AUD
    AUD -->|audio| STT
    STT -->|transcript| IM
    IM --> ST
    IM -->|prompt| LLM
    LLM -->|streamed tokens| OV
    SH --> FS
    PH -->|PNG image| LLM
    RAG --> DB
    CM -.->|reads keys| AUD & IM & PH
    WH --> OV & LA
    HELPERS --> SET
```

## 2. Dual-channel audio + STT

```mermaid
flowchart LR
    subgraph CaptureMac["macOS capture (Rust)"]
        M1["CoreAudio process-tap (14.4+)"]
        M2["ScreenCaptureKit fallback (13+, 48kHz)"]
    end
    subgraph CaptureWin["Windows capture (Rust)"]
        W1["WASAPI loopback (output device, eMultimedia role)"]
    end
    subgraph Mic["Microphone (all OS)"]
        C1["CPAL device capture"]
    end

    M1 & M2 --> SYS["System-audio stream"]
    W1 --> SYS
    C1 --> MICCH["Mic stream"]

    SYS --> DSP1["Silence suppress - RMS gate (VAD OFF for system)"]
    MICCH --> DSP2["Silence suppress - RMS gate + WebRTC VAD ON"]

    DSP1 -->|"PCM i16, 20ms frames"| STT1["STT instance #1 - label = interviewer"]
    DSP2 -->|"PCM i16, 20ms frames"| STT2["STT instance #2 - label = user"]

    STT1 & STT2 -->|"transcript {speaker, text, final}"| IE["IntelligenceManager.handleTranscript()"]
    STT1 -.WS/gRPC.-> P["Provider: Deepgram / Google / Soniox / ElevenLabs / OpenAI / Groq / Local Whisper / Natively API"]
    STT2 -.-> P
```

## 3. STT resilience / reconnect

```mermaid
flowchart TD
    START["Meeting start -> createSTTProvider(speaker)"] --> SEL["Pick provider from CredentialsManager.getSttProvider() (GoogleSTT = only static fallback if key missing)"]
    SEL --> CONN["Connect WS/gRPC - IPv4-only DNS + 15s handshake cap (dnsHelpers.ts)"]
    CONN --> OK{Connected?}
    OK -->|yes| STABLE["Run; reset backoff ONLY after 5s stable (anti-storm guard)"]
    OK -->|"error / close != 1000"| CLASS{Error type?}
    CLASS -->|"DNS ENOTFOUND/EAI_AGAIN"| DNS["Fixed 10s retry (does NOT burn backoff)"]
    CLASS -->|"auth / quota"| FATAL["Latch reconnect OFF (terminal) - don't drain quota"]
    CLASS -->|transient| BACK["Capped exponential backoff: base 1-1.5s, cap 30s, 2^N<=64, +-20% jitter; max attempts 10 (NativelyPro: indefinite)"]
    DNS --> CONN
    BACK --> CONN
    STABLE -->|socket drops| CLASS
    STABLE -. buffers <=500 chunks ~10s during gap .-> STABLE
```

## 4. Screenshot / vision pipeline

```mermaid
flowchart TD
    K1["Cmd/Ctrl+H (capture to queue)"] --> CAP
    K2["Cmd+Shift+Enter (capture AND analyze now)"] --> CAP
    K3["Selective region (CropperWindow draws rectangle)"] --> CAP
    CAP["ScreenshotHelper -> desktopCapturer.getSources({types:['screen']})"]
    CAP -->|"still PNG (multi-monitor stitch via sharp)"| Q["On-disk queue userData/screenshots/*.png - MAX 5 (FIFO)"]
    Q -->|"only file paths held in memory"| PROC["ProcessingHelper -> LLMHelper.generateWithVisionFallback()"]
    PROC --> CHAIN
    subgraph CHAIN["Vision fallback chain (first that works wins)"]
        direction LR
        V1["Codex CLI (if on)"] --> V2["OpenAI"] --> V3["Claude"] --> V4["Gemini Flash"] --> V5["Gemini Pro"] --> V6["Groq Llama-4 Scout"] --> V7["custom cURL / Ollama"]
    end
    CHAIN -->|streamed answer| OVL["Overlay window"]
    Q -.->|"cleared after analysis / clearQueues()"| DEL["deleted - never written to DB"]
```

## 5. Live intelligence pipeline

```mermaid
flowchart TD
    T["New transcript segment {speaker, text, final}"] --> ST
    ST["SessionTracker - rolling ~120s window, assistant reply history (anti-repeat), epoch summaries on overflow"] --> IC
    IC["IntentClassifier (3-tier)"] --> PL
    PL["PlannerDecision.planNextAssistantAction() -> silent | answer | clarify | recap | follow_up_questions | brainstorm"]
    PL -->|silent| NOOP["(stay quiet)"]
    PL -->|act| MCR["ModeContextRetriever - BM25-style retrieval over active persona reference files (PDF/DOCX) + custom context"]
    MCR --> PR["ProviderRouter.routeLLMProviders() - build fallback chain; respect data-scope policy + capability"]
    PR --> LLM["Mode-specific LLM (AnswerLLM / ClarifyLLM / RecapLLM / FollowUpLLM / CodeHintLLM / BrainstormLLM)"]
    LLM -->|"token stream: suggested_answer_token"| OV["Overlay (React) renders live"]
```

## 6. Intent classifier (3-tier)

```mermaid
flowchart TD
    IN["lastInterviewerTurn"] --> T1{"Tier 1: regex fast-path (<1ms)"}
    T1 -->|match| OUT["IntentResult {intent, confidence, answerShape}"]
    T1 -->|"no match & len>5"| T2{"Tier 2: zero-shot SLM - Xenova/mobilebert-uncased-mnli (~100MB) - top score >= 0.35?"}
    T2 -->|yes| OUT
    T2 -->|"no / model unavailable"| T3["Tier 3: context heuristic - short interviewer turn after >=2 replies -> follow_up; else general @ 0.5"]
    T3 --> OUT
```

## 7. Planner decision tree

```mermaid
flowchart TD
    A["planNextAssistantAction(input)"] --> B{text or images?}
    B -->|no| S1["silent: no_context"]
    B -->|yes| C{"cooldown active? (default 3000ms, skipped if images)"}
    C -->|yes| S2["silent: cooldown"]
    C -->|no| D{"confidence < 0.5 and no images?"}
    D -->|yes| S3["silent: low_confidence"]
    D -->|no| E{restatement + incomplete?}
    E -->|yes| R1["clarify"]
    E -->|no| F{recap pattern?}
    F -->|yes| R2["recap"]
    F -->|no| G{follow-up-questions pattern?}
    G -->|yes| R3["follow_up_questions"]
    G -->|no| H{clarify pattern?}
    H -->|yes| R4["clarify"]
    H -->|no| I{"brainstorm OR images OR detected coding Q?"}
    I -->|yes| R5["brainstorm"]
    I -->|no| J{"intent supports answer OR question signal (? / wh-word)?"}
    J -->|yes| R6["answer"]
    J -->|no| S4["silent: no_actionable_question"]
```

## 8. RAG / persistence lifecycle

```mermaid
flowchart LR
    subgraph Live["During meeting"]
        TR["Final transcript segments"] --> LIVE["LiveRAGIndexer (just-in-time, in-session)"]
    end
    subgraph Stop["On Stop (MeetingPersistence.stopMeeting)"]
        MP["snapshot transcript/usage/context"]
        MP -->|"retention=never -> skip"| SKIP["nothing stored"]
        MP --> SAVE["save meeting + transcript rows (isProcessed=false)"]
        SAVE --> BG["background: title + structured summary LLM"]
    end
    SAVE --> CHUNK["SemanticChunker (~400-token chunks, sliding overlap)"]
    CHUNK --> EMB["EmbeddingPipeline (OpenAI / Gemini / Ollama / local)"]
    EMB --> VEC[("vec_chunks_768 - sqlite-vec ANN index")]
    Q["Later: What did John say about the API?"] --> RET["VectorStore.search() - native sqlite-vec, else JS-cosine fallback (worker thread)"]
    VEC --> RET --> ANS["RAG answer via LLMHelper"]
```

## 9. Sequence: live question

```mermaid
sequenceDiagram
    autonumber
    participant Them as Interviewer (system audio)
    participant Native as Rust capture
    participant STT as STT provider
    participant IM as IntelligenceEngine
    participant LLM as LLM provider
    participant OV as Overlay
    Them->>Native: speaks "What's the time complexity?"
    Native->>Native: 20ms PCM frames, RMS gate
    Native->>STT: stream PCM (WebSocket/gRPC)
    STT-->>IM: transcript {speaker:'interviewer', final:true}
    IM->>IM: SessionTracker buffer + IntentClassifier -> coding/clarify
    IM->>IM: PlannerDecision -> "answer"
    IM->>LLM: prompt (rolling context + persona + retrieved refs)
    LLM-->>OV: stream tokens -> "O(n log n) because..."
    Note over OV: invisible to screen-share
```

## 10. Sequence: screenshot

```mermaid
sequenceDiagram
    autonumber
    participant U as You
    participant Main as Main process
    participant SH as ScreenshotHelper
    participant FS as Disk (<=5)
    participant Vis as Vision LLM
    participant OV as Overlay
    U->>Main: Cmd+Shift+Enter
    Main->>SH: capture
    SH->>SH: desktopCapturer.getSources() -> still PNG (stitch monitors)
    SH->>FS: save uuid.png (evict oldest if >5)
    Main->>Vis: send PNG + prompt (fallback chain)
    Vis-->>OV: stream solution/explanation
    Main->>FS: clear queue after analysis (temp only)
```

## 11. Run this repo as-is

```mermaid
flowchart TD
    A["git clone"] --> B["npm install (postinstall: rebuild sharp + better-sqlite3 + keytar, download models, ensure sqlite-vec, patch plist[mac])"]
    B --> C{".node native module present?"}
    C -->|"NOT committed to repo"| D["npm run build:native - needs Rust + platform C/C++ toolchain"]
    C -->|"official installer ships it"| E
    D --> E["npm start (Vite dev server + Electron)"]
    E --> F["Add >=1 STT key + >=1 LLM key (BYOK) OR run Ollama"]
    F --> G["Core works: dual-channel transcription, live answers, screenshot vision, local RAG, General mode"]
```

## 12. Operator: audio-silent triage

```mermaid
flowchart TD
    A["Audio silent / not transcribing"] --> B{STT status pill?}
    B -->|"failed"| F["Provider gave up: auth/quota/max-retries. Verify API key + quota; switch provider; restart"]
    B -->|"reconnecting"| R["Socket drops, backing off. Check network/DNS/VPN; self-recovers after 5s stable"]
    B -->|"connected, but no text"| G{Level bars moving? (Settings->Audio)}
    B -->|"awaiting-audio (stuck)"| C{Which channel is dead?}
    C -->|"mic / user"| MIC["Mic muted at OS or wrong device. Win: Settings->Privacy->Microphone. mac: re-grant Microphone"]
    C -->|"system / interviewer"| SYS{Banner text?}
    SYS -->|"screen-recording-revoked-rebuild (mac)"| TCC["macOS TCC broke after update (cdhash). Screen Recording: toggle Natively OFF/ON, restart"]
    SYS -->|"system-audio-permission-denied"| PERM["Screen Recording never granted (mac). Windows has no such permission"]
    SYS -->|"system-audio-stuck (~12s no chunks)"| STUCK["Output device changed (AirPods/HFP/BlackHole/HDMI). App rebuilds capture; re-select output or restart"]
    SYS -->|"no banner, just silence"| NONE["STT provider = none (silent-null) or key missing. Settings->Audio: confirm provider + key"]
    G -->|no| NATIVE{Native module loaded?}
    G -->|yes| NONE
    NATIVE -->|"dev build / no .node"| NB["loadNativeModule()=null -> empty device list. Run npm run build:native or reinstall official app"]
    NATIVE -->|loaded| NONE
```
