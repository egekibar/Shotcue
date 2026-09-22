# 04 — Claude Entegrasyonu ve Zamanlama (Scheduling)

> Araştırma tarihi: 2026-09-22 · Kapsam: Tasker'dan Claude'a görev iletmenin tüm yolları + zamanlama.
> Doğrulama makinesi: macOS 26.6.2, Claude Code CLI **2.1.278** (`/Users/egekibar/.local/bin/claude`), Claude Desktop **2.2553.1**, Node 22.23, Bun 1.4.2, Swift 6.4 (CLT).

---

## TL;DR

- **Headless `claude -p` abonelik (Pro/Max) login'i ile ÇALIŞIR.** Bu makinede doğrulandı: `claude auth status` → `{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max"}` ve `ANTHROPIC_API_KEY` **set değil**. API key zorunlu DEĞİL. Tek istisna: `--bare` bayrağı OAuth/keychain'i hiç okumaz ve `ANTHROPIC_API_KEY` ister — yani **Tasker `--bare` kullanmamalı**.
- **Görsel iletmek için en basit yol: prompt içinde mutlak dosya yolunu vermek.** Claude Code'un `Read` tool'u PNG/JPG'yi görsel içerik olarak modele verir (raw byte değil). İkinci yol: `--input-format stream-json` ile gerçek base64 `image` content block göndermek — SDK'da resmî örneği var.
- **Claude Desktop'a gerçekten görev "itmenin" yolu VAR: `claude://` deep link'leri — ve bunlar RESMÎ olarak dokümante edilmiş** ([support.claude.com](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link)). `claude://code/new?q=<prompt>&folder=<dizin>&file=<png>` yeni bir Code oturumu açar, `claude://cowork/new?...` Cowork görevi açar, ve (dokümante edilmemiş ama bundle'da doğrulanan) `claude://code/resume?session=<cli-session-id>` bir CLI oturumunu masaüstüne **import eder**.
- Deep link'ler prompt'u otomatik **göndermez** (composer'a doldurur), `q` **~14.000 karakterde kırpılır**, ve `folder` her seferinde onay diyaloğu gösterir (daha önce trust edilmiş olsa bile).
- **Zamanlama için önerilen: `launchd` LaunchAgent + Tasker'ın kendi job tablosu (hibrit).** Claude'un kendi çözümleri yetersiz: cloud **Routines** yerel dosyalara erişemez (taze GitHub clone) ve min. 1 saat; **Desktop scheduled tasks** yereldir ama Claude Desktop'ın açık + makinenin uyanık olmasını şart koşar; `/loop` yalnızca açık bir oturum boyunca yaşar ve 7 günde expire olur.
- **Claude Desktop scheduled tasks (Routines → Local) gerçekten yerelde çalışır** ve `~/.claude/scheduled-tasks/<task>/SKILL.md` dosyasına yazılır — Tasker bu dosyayı doğrudan üretebilir. Uyuyan makinede kaçan çalışmalar için **tek bir catch-up run** yapar (son 7 gün içindeki en yeni kaçan zaman).
- **Sonuç geri bildirimi için üç kanal var:** (1) `--output-format stream-json` canlı olay akışı, (2) `settings.json` içinde **HTTP hook** (`"type":"http","url":"http://127.0.0.1:<port>/..."`) → Tasker'a doğrudan callback, (3) `--output-format json` ile tek seferlik sonuç (`session_id`, `result`, `total_cost_usd`, `num_turns`, `duration_ms`, `permission_denials`).
- **Swift için resmî Anthropic SDK'sı YOK** (Python, TypeScript, C#, Go, Java, PHP, Ruby var). v1 için doğrudan Messages API'ye gitmeye gerek yok; `Process` ile `claude` binary'sini çalıştırmak hem ücretsiz (abonelik) hem tam agentic.
- `claude` binary'si **native Mach-O arm64** — Node/Bun sidecar'a ihtiyaç yok. Bu, "bundled Bun + Agent SDK" seçeneğini gereksiz kılıyor (Agent SDK zaten aynı binary'yi spawn ediyor) **ve** Agent SDK dokümantasyonu üçüncü taraf ürünlerde claude.ai login'ini yasaklıyor.
- **Kritik uyarı:** Tasker **App Sandbox'sız** (Developer ID, Mac App Store dışı) dağıtılmalı. Sandbox harici executable spawn etmeyi engeller ve `claude` kimlik bilgilerini macOS Keychain'den (`Claude Code-credentials`) okur.

---

## 1. Headless / Programatik Claude Code

### 1.1 Doğrulanmış CLI bayrak tablosu (2.1.278, `claude --help` çıktısından)

| Bayrak | Var mı | Not (bu sürümdeki gerçek davranış) |
|---|---|---|
| `-p, --print` | ✅ | Non-interactive. Workspace trust dialog atlanır. |
| `--output-format` | ✅ | `text` \| `json` \| `stream-json`. Sadece `--print` ile. |
| `--input-format` | ✅ | `text` \| `stream-json`. Sadece `--print` ile. |
| `--include-partial-messages` | ✅ | `--print` + `--output-format=stream-json` gerekir. |
| `--resume, -r` | ✅ | Session ID, isim **veya** transcript `.jsonl` mutlak yolu. |
| `--continue, -c` | ✅ | Aynı dizindeki en son konuşma. |
| `--session-id <uuid>` | ✅ | **Önceden belirlenen UUID** — Tasker job ID'si olarak kullanılabilir. |
| `--fork-session` | ✅ | Resume ederken yeni ID üretir. |
| `--model` | ✅ | Alias (`opus`, `sonnet`, `haiku`, `fable`) veya tam ad. |
| `--effort` | ✅ | `low\|medium\|high\|xhigh\|max`. |
| `--permission-mode` | ✅ | `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`. |
| `--permission-prompts` | ✅ | `host` \| `none`. **Unattended run için `none`.** |
| `--allowedTools` / `--disallowedTools` | ✅ | `"Bash(git diff *)"` gibi pattern destekli. |
| `--dangerously-skip-permissions` | ✅ | `bypassPermissions` ile eşdeğer. |
| `--add-dir` | ✅ | Ek erişim dizinleri (screenshot klasörü için gerekli!). |
| `--append-system-prompt` / `--system-prompt` | ✅ | `--append-system-prompt-file` de var. |
| `--max-turns` | ✅ | Sadece `--print`. Limitte hata ile çıkar. |
| `--max-budget-usd` | ✅ | **Var.** Sadece `--print`. Subagent harcaması da sayılır. |
| `--json-schema` | ✅ | Yapılandırılmış çıktı → `structured_output` alanı. |
| `--agents <json>` | ✅ | Dinamik subagent tanımı. |
| `--mcp-config` | ✅ | JSON dosyası veya string. `--strict-mcp-config` ile izolasyon. |
| `--settings <file-or-json>` | ✅ | Hook'ları buradan enjekte edebiliriz. |
| `--verbose` | ✅ | stream-json ile birlikte gerekir. |
| `--bg / --background` | ✅ | `-p` ile **birleşmez** (reddedilir). |
| `--bare` | ✅ | ⚠️ OAuth/keychain okumaz → API key zorunlu. **Kullanmayın.** |
| `--no-session-persistence` | ✅ | `-p` ile transcript yazmaz (resume edilemez). |
| `claude schedule` | ❌ | Böyle bir subcommand **yok** (`/schedule` slash command'dır, cloud routine oluşturur). |
| `claude desktop` | ❌ | Subcommand yok; `/desktop` slash command olarak binary içinde mevcut. |
| `claude remote-control` | ✅ | claude.ai/code veya mobil uygulamadan yerel oturumu sürmek için. |
| `claude mcp serve` | ✅ | Claude Code'u MCP sunucusu olarak çalıştırır. |
| `claude agents --json` | ✅ | Aktif oturumları JSON olarak listeler (TTY gerektirmez). |

### 1.2 Abonelik mi, API key mi? (KRİTİK)

Bu makinede **doğrulandı** (salt-okunur `claude auth status`):

```json
{ "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
  "subscriptionType": "max", "configDirectory": "/Users/egekibar/.claude" }
```

`ANTHROPIC_API_KEY` set değil. Dokümantasyon bunu dolaylı ama net biçimde doğruluyor — `--bare` anlatımında: *"Set `ANTHROPIC_API_KEY` before running it, because bare mode doesn't use your subscription login"* ve `--bare` bayrak açıklamasında: *"Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper via --settings (OAuth and keychain are never read)"*. Yani **`--bare` olmayan `claude -p` abonelik login'ini kullanır.** Kimlik bilgileri macOS Keychain'de `Claude Code-credentials` altında.

**Maliyet sonucu:** Tasker'ın headless run'ları kullanıcının Max aboneliğinden düşer, ayrı API faturası oluşmaz. `--output-format json`'daki `total_cost_usd` yine de *client-side estimate* olarak raporlanır (gösterim için kullanılabilir, fatura değildir).

⚠️ **Sınır:** Agent SDK quickstart'ı açıkça yazıyor: *"Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK."* Bu, **başkalarına claude.ai login'i sunmayı** yasaklar. Tasker kullanıcının kendi makinesinde kendi `claude` kurulumunu ve kendi login'ini kullanıyorsa bu madde kapsamına girmez; ama Tasker'ı dağıtırken "Claude Code kurulu ve login olmuş olmalı" ön koşulunu koymak, kendi auth katmanını kurmamak gerekir.

### 1.3 Görsel + not gönderme: üç yöntem

**A) Yol referansı (v1 için önerilen).** `Read` tool'u görselleri okur: *"PNG, JPG, and other image formats are returned as visual content that Claude can see, not as raw bytes. Claude Code resizes and recompresses large images... an image that is still larger than 500KB after that resize is re-encoded as a JPEG at reduced quality."* Prompt'a mutlak yolları yazmak yeterli; `--add-dir` ile screenshot klasörünü erişilebilir kılın.

**B) `--input-format stream-json` ile gerçek base64 image block.** Mesaj şekli (Agent SDK streaming-input dokümanından, birebir):

```json
{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[
  {"type":"text","text":"Review this architecture diagram"},
  {"type":"image","source":{"type":"base64","media_type":"image/png","data":"<BASE64>"}}
]}}
```

Alan adları **`source` + `media_type` + `data`** (Messages API ile aynı). Tek mesajda birden fazla image + text bloğu olabilir. Not: stdin 10MB ile sınırlı; 4-5 büyük PNG'yi base64'e çevirince bu limit kolayca aşılır → **çok görselli batch'lerde A yöntemi daha güvenli.**

**C) stdin pipe.** `cat note.txt | claude -p "..."` — sadece metin için.

### 1.4 Sonucu yakalama

`--output-format json` tek satır JSON döndürür. 2.1.278 binary'sinde varlığı doğrulanan alanlar:

`type`, `subtype`, `is_error`, `duration_ms`, `duration_api_ms`, `num_turns`, `result`, `session_id`, `total_cost_usd`, `usage`, `modelUsage`, `permission_denials`, `structured_output`, `uuid`.

`subtype` değerleri (binary'den): `success`, `error_max_turns`, `error_during_execution`, `error_max_budget_usd`.

`--output-format stream-json --verbose` canlı olay akışı verir: `system/init` (model, tools, `mcp_servers`, `mcp_server_errors`, `plugins`, `plugin_errors`, `capabilities`), `assistant`/`user` mesajları, `system/api_retry` (retry göstergesi için), ve son satırda `result`. `--include-partial-messages` ile token-token `stream_event` deltaları gelir.

### 1.5 Oturuma geri dönmek

- Terminal: `claude --resume <session_id>` — **herhangi bir dizinden** çalışır (v2.1.223+ makine genelinde arar).
- Desktop: `claude://code/resume?session=<session_id>` → uygulama `importCliSession` ile oturumu Code sekmesine alır (bkz. §3).
- `-p` ile başlatılan oturumlar session picker'da ve `--continue`'da **görünmez**; ama ID ile `--resume` çalışır. Bu yüzden Tasker **her job için `--session-id <uuid>` üretip saklamalı**.

### 1.6 Unattended çalıştırma ve riskler

| Mod | Davranış | Risk |
|---|---|---|
| `--permission-mode acceptEdits` | Dosya yazma + `mkdir/touch/mv/cp` otomatik onay. Diğer shell komutları hâlâ kural ister. | Düşük-orta. **v1 için önerilen.** |
| `--permission-mode auto` | Bir sınıflandırıcı çoğu aksiyonu inceler. | Orta. `--permission-prompts none` ile birleştirilmeli. |
| `--permission-mode dontAsk` | Prompt gerektiren her şey reddedilir, gerisi çalışır. | En güvenli kilitli mod. |
| `bypassPermissions` / `--dangerously-skip-permissions` | Tüm kontroller atlanır. | **Yüksek.** Doküman "yalnızca internetsiz sandbox" diyor. Tasker varsayılanı olmamalı. |

Ek güvenlik: `--max-turns`, `--max-budget-usd`, `--disallowedTools "Bash(rm *)"`, ve `--add-dir` ile dizin kapsamını daraltma. Unattended job'larda `--permission-prompts none` şart: aksi halde run, kimsenin cevaplamayacağı bir prompt'ta asılı kalır.

`-p` run'ını SIGTERM ile durdurursanız exit code **143** olur ve yarım tur kaydedilmez; nazik durdurma için SIGINT gönderin.

**Kaynaklar:** https://code.claude.com/docs/en/headless · https://code.claude.com/docs/en/cli-reference · https://code.claude.com/docs/en/permission-modes · https://code.claude.com/docs/en/tools-reference · https://code.claude.com/docs/en/sessions

---

## 2. Agent SDK vs. `Process` vs. Doğrudan API

### 2.1 Agent SDK durumu (Eylül 2026)

| Konu | Durum |
|---|---|
| npm `@anthropic-ai/claude-agent-sdk` | **0.3.278** |
| PyPI `claude-agent-sdk` | **0.2.157** |
| Görsel girdi | ✅ ama **yalnızca streaming input** modunda (single-message mode görsel kabul etmez) |
| Session | ✅ `resume`, `forkSession`, `continue`; `session_id` her result mesajında |
| Hooks | ✅ `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `SubagentStop`… |
| Streaming | ✅ `includePartialMessages` / `include_partial_messages` |
| Maliyet | ✅ `total_cost_usd`, `modelUsage`, per-step `usage` |
| Auth | Dokümante edilen tek yol **`ANTHROPIC_API_KEY`** (+ Bedrock/Vertex/Foundry). claude.ai login'i üçüncü taraf ürünler için yasak. |
| Mimari | **Claude Code binary'sini spawn eder** — bağımsız bir implementasyon değil. `pathToClaudeCodeExecutable` ile harici binary'ye yönlendirilebilir. |

### 2.2 Swift SDK durumu

Anthropic'in **resmî Swift SDK'sı yok**. Resmî diller: Python, TypeScript, C#, Go, Java, PHP, Ruby. Topluluk paketleri:

| Paket | ★ | Streaming | Vision | Not |
|---|---|---|---|---|
| [jamesrochabrun/SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) | ~251 | ✅ | ✅ base64 | MIT, iOS 15+/macOS 12+, en olgun seçenek |
| [GeorgeLyon/SwiftClaude](https://github.com/GeorgeLyon/SwiftClaude) | ~74 | ✅ | ✅ `NSImage`/`UIImage` native | Swift 6, macOS 15+, `@Tool` macro |
| [jamesrochabrun/ClaudeCodeSDK](https://github.com/jamesrochabrun/ClaudeCodeSDK) | ~98 | — | — | **Claude Code CLI'yi Swift'ten sürmek için**; macOS 13+, session + MCP desteği |
| [fumito-ito/AnthropicSwiftSDK](https://github.com/fumito-ito/AnthropicSwiftSDK) | ~18 | ✅ SSE | ✅ image+PDF | Apache 2.0, Bedrock/Vertex eklentileri |
| [taumatix/anthropic-swift](https://github.com/taumatix/anthropic-swift) | ~0 | ✅ | ? | Yeni (v0.2.0, Eyl 2026), geniş API kapsamı |

### 2.3 Karşılaştırma ve karar

| Yaklaşım | Maliyet | Agentic güç | Karmaşıklık | Karar |
|---|---|---|---|---|
| **Swift `Process` → `claude` CLI** | **Abonelikten düşer (ek ücret yok)** | Tam (tüm tool'lar, hooks, MCP, skills) | Düşük — native binary, runtime bağımlılığı yok | ✅ **v1** |
| Bundled Bun/Node + Agent SDK | API key zorunlu → **ayrı fatura** | Tam (zaten aynı binary'yi spawn ediyor) | Yüksek — sidecar paketleme, imzalama, notarization | ❌ Gereksiz ara katman |
| Doğrudan Messages API (URLSession) | API key → ayrı fatura | Yok (tool loop'u kendin yazarsın) | Orta | 🔶 v2, sadece uygulama içi analiz/sohbet için |

**Öneri:** v1'de `Process`. Büyüme yolu: (a) v1.5'te `--input-format stream-json` ile interaktif oturum (follow-up mesaj gönderebilme), (b) v2'de yalnızca "bu screenshot'ta ne var?" gibi hızlı, kod tabanına dokunmayan analizler için SwiftAnthropic/URLSession üzerinden Messages API.

**Kaynaklar:** https://code.claude.com/docs/en/agent-sdk/quickstart · https://code.claude.com/docs/en/agent-sdk/streaming-input · https://code.claude.com/docs/en/agent-sdk/sessions · https://code.claude.com/docs/en/agent-sdk/cost-tracking · https://platform.claude.com/docs/en/cli-sdks-libraries/overview

---

## 3. Claude DESKTOP entegrasyonu — `claude://` deep link'leri

Deep link'ler **resmî olarak dokümante edilmiş**: [Open Claude Desktop with a link](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link). Aşağıdaki tablo o dokümanı, **yerel bundle analiziyle** (`/Applications/Claude.app/Contents/Resources/app.asar`, sürüm 2.2553.1) çapraz doğrulanmış hâlde veriyor — bundle'da dokümante edilmeyen ekstra rotalar da çıktı.

### 3.1 URL scheme kaydı (doğrulandı)

`Info.plist` → `CFBundleURLSchemes: ["claude"]`. LaunchServices dökümü `claimed schemes: claude:` ve `claimed UTIs: ... dyn... (.mcpb), dyn... (.dxt)` gösteriyor — yani **Claude.app hem `claude://` hem de `.mcpb`/`.dxt` dosyalarının sahibi**. Swift'ten `NSWorkspace.shared.open(url)` ile tetiklenir; uygulama kapalıysa macOS başlatır.

### 3.2 Doğrulanmış rotalar

| Deep link | Ne yapar | Parametreler | Kaynak |
|---|---|---|---|
| `claude://code/new?q=<prompt>&folder=<abs>&file=<abs>` | Code sekmesinde **yeni oturum**, prompt composer'a dolar | `q` \| `prompt`, `folder`, `file` (tekrarlanabilir) | Resmî |
| `claude://cowork/new?q=…&folder=…&file=…` | Cowork görevi (`/task/new`), **dosya ekleriyle** | aynı | Resmî |
| `claude://claude.ai/new?q=<text>` | Normal chat, prefilled | `q`, `surface`, `composer` | Resmî |
| `claude://claude.ai/chat/<id>` · `claude://claude.ai/project/<id>` | Var olan sohbet/proje | — | Resmî |
| `claude://code/resume?session=<cli-session-id>` | **CLI oturumunu masaüstüne import eder** (`importCliSession`) | `session` | Bundle |
| `claude://code/continue?session=last` | Son Code oturumunu açar | `session=last` veya ID | Bundle |
| `claude://code/needs-input` | En uzun süredir bekleyen oturuma gider | — | Bundle |
| `claude://code/new?ssh_host=…` | Uzak SSH hedefinde oturum | `ssh_host`, `ssh_port`, `ssh_folder` | Bundle |

### 3.3 Önemli kısıtlar

1. **`q` ~14.000 karakterde kırpılır** — bundle'da sabit `rA = 14336` (`?.slice(0, rA)`). Uzun promptlar **sessizce** kesilir → Tasker uzun notu bir `.md` dosyasına yazıp prompt'ta yoluna referans vermeli.
2. Deep link prompt'u **otomatik göndermez** — composer'a doldurur, kullanıcı Enter'a basar. Bu aslında iyi: insan onayı doğal olarak devrede kalır. Yani deep link **"zamanlanmış otomatik gönderim" için uygun değildir**, sadece "şimdi elimle bak" akışı için.
3. **`folder` her zaman onay ister:** *"Any folder supplied through a link is treated as untrusted. Claude Desktop always shows a confirmation dialog before adopting it as the working directory, even if you've trusted that folder before."*
4. Tüm parametre değerleri **URL-encoded** olmalı; `file`/`folder` **mutlak yol** olmalı (bundle `isAbsolute && resolve(e)===e` kontrolü yapıyor).
5. ⚠️ **Doğrulanması gereken tutarsızlık:** Resmî doküman `file` parametresini hem Code hem Cowork için listeliyor; ancak 2.2553.1 bundle'ında `code/new` handler'ı `getAll("file")` ile okuyup yalnızca telemetriye (`has_file`) yazıyor ve son URL'ye sadece `q` + `folder` + `src` iletiyor — dosyaları gerçekten iliştiren kod yolu `cowork/new` tarafında. **Prototipte ikisini de deneyip hangisinin görseli gerçekten eklediğini ölçün**; şüphede kalırsanız `cowork/new` kullanın.
6. `ssh_*` parametreleri `folder` ile birlikte verilirse `ambiguous` diye reddediliyor.

### 3.4 CLI → Desktop köprüsü

Binary içinde `/desktop` slash command'ı mevcut (doğrulandı). Dokümantasyona göre CLI oturumunu kaydedip masaüstünde açar; macOS + x64 Windows'ta ve **abonelik auth'u ile** (API key ile değil) çalışır. Tasker için pratik yol yine `claude://code/resume?session=<id>` deep link'i.

### 3.5 MCP rotası (alternatif tasarım)

Tasker yerel bir **MCP sunucusu** sunabilir; kullanıcı "bekleyen Tasker görevlerimi getir" deyince Claude screenshot + notları çeker.

**Görsel döndürme formatı.** MCP spesifikasyonunda (revizyon 2026-07-28) `tools/call` sonucundaki image content block şu şekildedir — dikkat: **Messages API'den FARKLI alan adları**:

```json
{ "type": "image", "data": "<base64>", "mimeType": "image/png",
  "annotations": { "audience": ["user","assistant"], "priority": 0.9 } }
```

Yani MCP'de `data` + `mimeType` (Messages API'de `source.data` + `source.media_type`). Alternatif olarak `EmbeddedResource` (`{"type":"resource","resource":{"uri":…,"mimeType":…}}`) kullanılabilir, ancak salt **resource link**'lerin render edilmesi garanti değil — gömülü binary daha güvenilir.

**Kurulum yolları.** Claude Desktop MCP sunucularını `~/Library/Application Support/Claude/claude_desktop_config.json` → `mcpServers` bloğundan yükler; `stdio` (`command`/`args`/`env`), `http` (`"type":"http","url":…`) ve deprecated `sse` destekleniyor. **Bu makinede o blok şu an boş** (`mcpServers count: 0`; dosyada yalnızca `coworkUserFilesPath` + `preferences` var), yani ya Tasker bu JSON'u yazacak ya da:

- **`.mcpb` Desktop Extension** (eski adı `.dxt`) ile **tek tıkla kurulum** — ZIP arşivi + `manifest.json` (`name`, `version`, `runtimeType: node|python|binary`, `entryPoint`, `userConfig[]`). Kullanıcı dosyayı çift tıklar veya Settings → Extensions'a sürükler; Claude Desktop bağımlılıkları ve credential'ları (macOS Keychain) yönetir. **Yerel doğrulama:** Claude.app `dyn.ah62d4rv4ge80425uqk (.mcpb)` ve `dyn.ah62d4rv4ge80k8dy (.dxt)` UTI'larını claim ediyor → çift tıklama gerçekten çalışır. Node runtime Desktop ile birlikte geliyor, yani **Tasker'ın MCP sunucusunu Node ile yazması ek runtime paketlemeden kaçınmayı sağlar**; alternatif olarak Swift ile statik binary derleyip `runtimeType: "binary"` kullanılabilir.
- Claude Code tarafında: `claude mcp add-from-claude-desktop` ile import, veya `claude mcp add`/`--mcp-config`.
- Desktop'ın Settings → Connectors → "Add custom connector" akışı **yalnızca uzak HTTP/SSE** sunucular içindir ve `claude_desktop_config.json`'a yazmaz. **Bir uygulamanın kendini connector olarak otomatik kaydettirmesi için API yok.**

**Değerlendirme:** MCP rotası bir **"pull" modelidir** — kullanıcının Claude'a *sorması* gerekir; Tasker'ın zamanlanmış "gönder" akışını tek başına karşılamaz. Ayrıca MCP tool sonuçları **`MAX_MCP_OUTPUT_TOKENS`** (varsayılan **25.000** token, uyarı eşiği 10.000) limitine tabidir ve **görseller per-tool `anthropic/maxResultSizeChars` override'ını kullanamaz** — her zaman global bütçeden düşer. Tipik bir 300KB screenshot ≈ 2-3k token, yani ~8-10 görselde limit dolar. **Öneri: MCP'yi v2'de tamamlayıcı okuma kanalı olarak ekleyin (tool'lar görseli değil önce metadata listesini döndürsün, görseli ancak istenince versin), birincil gönderim kanalı yapmayın.**

### 3.6 Desktop'ta yerel zamanlanmış görevler — VAR

Claude Desktop'ın **Code → Routines → New routine → Local** akışı yerel scheduled task oluşturuyor. Bu oturumda bu araçlar canlı olarak mevcut: `create_scheduled_task`, `list_scheduled_tasks`, `update_scheduled_task`, `run_scheduled_task`, `list_task_runs`, `delete_scheduled_task`. Görevler **`~/.claude/scheduled-tasks/<task-id>/SKILL.md`** olarak diske yazılıyor (bu makinede klasör henüz yok — hiç oluşturulmamış). Detaylar §5'te.

**Kaynaklar:** https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link · `/Applications/Claude.app/Contents/Resources/app.asar` + `Info.plist` + `lsregister -dump` (yerel analiz) · https://code.claude.com/docs/en/desktop · https://code.claude.com/docs/en/mcp · https://code.claude.com/docs/en/desktop-scheduled-tasks · https://modelcontextprotocol.io/specification/2026-07-28/server/tools · https://github.com/modelcontextprotocol/mcpb · https://www.anthropic.com/engineering/desktop-extensions · https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp

---

## 4. Doğrudan Messages API (ikincil yol, kompakt)

**Model ID'leri (Eylül 2026):**

| Model | ID | Context | Max output | Vision | Fiyat (in/out, $/MTok) |
|---|---|---|---|---|---|
| Claude Fable 5.1 | `claude-fable-5-1` | 1M | 128K | ✅ | 10 / 50 |
| Claude Opus 5 | `claude-opus-5` | 1M | 128K | ✅ | 5 / 25 |
| Claude Sonnet 5 | `claude-sonnet-5` | 1M | 128K | ✅ | 2 / 10 |
| Claude Haiku 4.5 | `claude-haiku-4-5` | 200K | 64K | ✅ | 1 / 5 |

Prompt caching: 5dk write 1.25×, 1sa write 2×, cache hit 0.1× (Fable/Mythos 5.1'de 0.025×). Batch API %50 indirim.

**Vision kuralları:** `base64` / `url` / Files API (`file_id`) kaynak tipleri. JPEG, PNG, GIF, WebP. Max 10MB, max 8000×8000px. Token formülü: `ceil(w/28) × ceil(h/28)` visual token. Standart tier uzun kenar **1568px**, Claude 4.7+ high-res tier **2576px** (max 4784 visual token). İstek başına 100 görsel (200K modeller) / 600 (diğerleri); 20'den fazla görselde per-image boyut limiti sıkılaşır. **Görseli metinden önce koymak kalite açısından tercih edilir.**

**Thinking:** modern modellerde `{"thinking":{"type":"adaptive"}}` + `{"output_config":{"effort":"low|medium|high"}}`. Eski `{"thinking":{"type":"enabled","budget_tokens":N}}` 4.7+'ta reddediliyor.

**Streaming (Swift):** `POST /v1/messages` + `"stream": true`. Header'lar: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. SSE olayları: `message_start` → `content_block_start` → `content_block_delta` (`text_delta` / `thinking_delta` / `input_json_delta`) → `content_block_stop` → `message_delta` (stop_reason + usage) → `message_stop`, aralarda `ping` ve `error`. Swift'te `URLSession.bytes(for:)` ile `AsyncSequence<UInt8>` alıp satır satır tamponlayın; `data:` satırlarını JSON olarak çözün.

**Kaynaklar:** https://platform.claude.com/docs/en/about-claude/models/overview · https://platform.claude.com/docs/en/build-with-claude/vision · https://platform.claude.com/docs/en/build-with-claude/streaming · https://platform.claude.com/docs/en/about-claude/pricing

---

## 5. Zamanlama: "sonra gönder" ve "her akşam kuyruğu gönder"

### 5.1 Üç Claude-yerlisi seçeneğin resmî karşılaştırması

| | Cloud **Routines** | **Desktop** scheduled task | **`/loop`** |
|---|---|---|---|
| Nerede çalışır | Anthropic cloud | **Senin makinen** | Senin makinen |
| Makine açık olmalı | Hayır | **Evet** | Evet |
| Açık oturum gerekir | Hayır | Hayır | **Evet** |
| Restart'a dayanıklı | Evet | **Evet** | `--resume` ile kısmen |
| **Yerel dosya erişimi** | **Hayır (taze clone)** | **Evet** | Evet |
| Min. aralık | **1 saat** | **1 dakika** | 1 dakika |
| İzin promptları | Yok (tam otonom) | Görev başına ayarlanır | Oturumdan miras |

**Sonuç:** Tasker'ın çekirdek akışı (yerel screenshot dosyaları) için **cloud Routines elenir** — routine her çalışmada GitHub'dan taze clone alır, Mac'teki `~/Library/.../Tasker/shots/*.png` dosyalarına asla erişemez. `/loop` de elenir: açık bir CLI oturumu şart ve 7 günde expire oluyor.

### 5.2 (c) Desktop scheduled tasks — gerçek ama kırılgan

Doğrulanan davranışlar (doküman + canlı MCP tool açıklamaları):

- Desktop **açıkken** her dakika kontrol eder, görev zamanı gelince **yeni bir oturum başlatır**; sidebar'da **Scheduled** bölümünde görünür + masaüstü bildirimi gelir.
- *"Tasks only run while the desktop app is running and your computer is awake. If your computer sleeps through a scheduled time, the run is skipped."* Ayarlarda **Keep computer awake** açılabilir, ama **kapak kapanınca yine uyur.**
- **Catch-up:** uygulama açılışında/uyanışta son 7 gündeki kaçan çalışmalar kontrol edilir ve **yalnızca en yeni kaçan zaman için tek bir run** başlatılır, eskisi atılır. → *"A task scheduled for 9am might run at 11pm if your computer was asleep all day."* Prompt'a zaman guard'ı yazmak gerekir.
- Görev başına **permission mode**; Manual modda izin gerekirse run **askıda kalır** ve oturum sidebar'da bekler. İlk `Run now`'da "always allow" seçilerek sonraki run'lar otomatikleşir.
- Prompt diskte: `~/.claude/scheduled-tasks/<task-name>/SKILL.md` (YAML frontmatter: `name`, `description`; gövde = prompt). **Schedule/folder/model bu dosyada değil.**
- Çalışan bir görev `update_scheduled_task` MCP tool'u ile **kendi zamanlamasını değiştirebilir**.
- Cron, kullanıcının **yerel saat diliminde** değerlendirilir. Her görev deterministik birkaç dakikalık stagger gecikmesi alır.

### 5.3 (a) Uygulama içi scheduler + (b) launchd — önerilen hibrit

**Neden hibrit:** Menü çubuğu uygulaması kullanıcı oturumu boyunca zaten çalışır, ama uygulama kapalıyken/çöktüğünde iş kaçar. `launchd` bunu kapatır.

**Katman 1 — Kalıcı job tablosu (source of truth).** SQLite/GRDB: `job_id (UUID)`, `scheduled_at`, `cron`, `state (pending|running|done|failed)`, `attempt`, `session_id`, `last_error`, `payload_path`. Bu tablo her iki tetikleyicinin de okuduğu tek gerçek.

**Katman 2 — `launchd` LaunchAgent** (`~/Library/LaunchAgents/com.tasker.scheduler.plist`):
- `StartCalendarInterval` ile sabit saatler (ör. her akşam 19:00), veya `StartInterval` ile dakikalık tick.
- **Kritik avantaj:** `launchd`, makine uyurken kaçan `StartCalendarInterval` işini **uyanışta bir kez çalıştırır** — Desktop scheduled task'ın "skipped" davranışının aksine.
- Çağırdığı şey `tasker-cli send --job <id>` (uygulama bundle'ı içine gömülü küçük bir helper) olmalı; bu helper due job'ları tablodan okur, `claude -p` çalıştırır, sonucu tabloya yazar.
- `RunAtLoad: false`, `ProcessType: Background`, `StandardErrorPath` ile log.

**Katman 3 — Uygulama içi `DispatchSourceTimer`** (uygulama açıkken anlık UI geri bildirimi için). `Timer` yerine `DispatchSourceTimer` kullanın: `Timer` run-loop moduna bağlıdır ve menü çubuğu etkileşimlerinde kayabilir. **`NSBackgroundActivityScheduler` kullanmayın** — sistem ne zaman çalıştıracağını kendi seçer (tolerance geniş), "09:00'da gönder" garantisi vermez.

**Uyku/uyanma yakalaması:**
```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in scheduler.reconcileOverdueJobs() }
```
`reconcileOverdueJobs()` tabloda `scheduled_at < now && state == .pending` olanları toplar. **Politika kararı:** kaçan tekrarlı job'lar için Claude Desktop'ın davranışını taklit edin — hepsini değil, **yalnızca en yeni kaçanı** çalıştırın (queue flood'u önler).

**Hata / retry / bildirim:**
- `claude` exit code ≠ 0 veya `is_error: true` → `attempt += 1`, exponential backoff (1dk, 5dk, 15dk), max 3 deneme.
- `subtype == "error_max_budget_usd"` veya `"error_max_turns"` → **retry etme**, kullanıcıya sor (bütçe/tur limitini artırsın mı).
- Exit code **143** = SIGTERM ile öldürüldü (ör. logout) → sonraki tick'te yeniden dene.
- `UNUserNotificationCenter` ile bitişte bildirim; `UNNotificationAction` ile "Sonucu aç" / "Terminal'de devam et" butonları. Hata bildirimlerinde `.timeSensitive` interruption level uygun.
- Ağ yoksa / login düşmüşse `claude -p` sonucu `result` alanında auth hatası basar → Tasker bunu yakalayıp "Claude Code'a tekrar giriş yapın" der.

**Kaynaklar:** https://code.claude.com/docs/en/desktop-scheduled-tasks · https://code.claude.com/docs/en/routines · https://code.claude.com/docs/en/scheduled-tasks

---

## 6. Sonuçları kullanıcıya geri vermek

**(i) Tasker içinde özet + maliyet.** `--output-format json`'dan `result` (metin özet), `total_cost_usd`, `num_turns`, `duration_ms`, `permission_denials`. Daha yapılandırılmış istiyorsanız `--json-schema` ile `structured_output` alanını zorlayın (örn. `{files_changed: string[], summary: string, needs_review: boolean}`).

**(ii) Canlı ilerleme.** İki seçenek:
- `--output-format stream-json --verbose` → Tasker `Process`'in `standardOutput` pipe'ını NDJSON olarak okur, `assistant` mesajlarındaki `tool_use` bloklarını "Şu an: Read src/Foo.swift" gibi gösterir.
- **HTTP hook** (daha az bağlantı gerektirir): `--settings` ile geçici bir JSON'a:
  ```json
  {"hooks":{"Stop":[{"hooks":[{"type":"http","url":"http://127.0.0.1:8787/tasker/stop"}]}]},
   "Notification":[{"matcher":"permission_prompt","hooks":[{"type":"http","url":"http://127.0.0.1:8787/tasker/needs-input"}]}]}
  ```
  `Stop` hook input'u `session_id`, `transcript_path`, `cwd`, `stop_reason`, `last_assistant_message` taşır. `Notification` `permission_prompt` matcher'ı run'ın izin beklediğini bildirir.

**(iii) Terminalde açmak.**
```bash
open -a Terminal  # veya iTerm
osascript -e 'tell app "iTerm" to create window with default profile command "claude --resume <SESSION_ID>"'
```
Daha temiz yol: Tasker geçici bir `.command` dosyası yazıp `NSWorkspace.open` ile açar (kullanıcının varsayılan terminalini kullanır).

**(iv) Claude Desktop'ta açmak.** `claude://code/resume?session=<SESSION_ID>` → oturum Code sekmesine import edilir. Bu, headless run'ı masaüstünde devam ettirmenin **resmî olmayan ama çalışan** yolu.

**(v) Diff / PR.** `cwd` biliniyor → `git -C <cwd> diff` çıktısını Tasker içinde gösterin, ya da `open -a "GitHub Desktop"` / `gh pr view --web`. Claude PR açtıysa `result` metninde URL genelde bulunur; `--json-schema` ile `pr_url` alanını garantiye alabilirsiniz.

**(vi) Transcript geçmişi.** Doğrulanmış yol formatı: **`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`** — `<encoded-cwd>`, çalışma dizini yolundaki **alfanümerik olmayan her karakterin `-` ile değiştirilmesiyle** üretilir. Bu makinedeki gerçek örnekler doğruladı: `/Users/egekibar/Github/Teklif-Backend` → `-Users-egekibar-Github-Teklif-Backend`; worktree yolundaki `.claude` → `--claude` (nokta da `-` oluyor). 200 karakteri aşan adlar kırpılıp hash ekleniyor. ⚠️ Doküman açıkça uyarıyor: *"The entry format is internal to Claude Code and changes between versions, so scripts that parse these files directly can break on any release."* → Tasker bu dosyaları **birincil veri kaynağı yapmasın**; sadece "geçmişi göster" gibi best-effort özellikler için okusun.

---

## 7. Screenshot görevi için prompt tasarımı

### 7.1 Yapı

Claude Code'a giden mesaj şu bölümleri içermeli, bu sırayla:

1. **Görev tipi** (tek satır): `BUG FIX` / `FEATURE` / `ANALYZE ONLY`.
2. **Başlık** — Tasker'daki görev adı.
3. **Görsel yolları** — mutlak, her biri kendi satırında, kısa bir "ne gösteriyor" etiketiyle. (Görsel önce, metin sonra kuralı burada da geçerli.)
4. **Not transkripti** — sesli notun yazıya dökülmüş hâli, ham olarak, "kullanıcının kendi ifadesi" etiketiyle.
5. **Beklenen çıktı** — net ve ölçülebilir.
6. **Kısıtlar** — dokunma denmeyen yerler, test komutu, vs.

### 7.2 `--append-system-prompt` ile sabit davranış

```
You are processing a task captured by Tasker, a screenshot+voice note tool.
The screenshots are UI captures from the running app; read them with the Read tool before editing code.
The note transcript is dictated speech: it may contain filler words and transcription errors. Interpret intent, do not quote it literally.
Always finish with: (1) a 3-line summary, (2) the list of files you changed, (3) what you could NOT do and why.
If the task type is ANALYZE ONLY, do not modify any file.
```

### 7.3 Batch stratejisi

| Durum | Strateji |
|---|---|
| Aynı ekranın/akışın 2-5 görseli, tek bir konu | **Tek task, çok görsel.** Claude bağlamı birleştirir. |
| Farklı konular (biri login bug'ı, biri dashboard isteği) | **Görsel başına ayrı task**, ayrı `--session-id`. Aksi halde Claude öncelik sırası uydurur. |
| Aynı proje, farklı konular, "akşam kuyruğu" | **Ayrı `claude -p` run'ları, sıralı** (paralel değil — aynı repo'da eşzamanlı edit çakışır). |
| Farklı projeler | Zaten ayrı `cwd` → ayrı run, paralel çalıştırılabilir. |

### 7.4 Somut örnek prompt

```
TASK TYPE: BUG FIX
TITLE: Sipariş listesinde tarih filtresi yanlış sonuç veriyor

SCREENSHOTS (read these first with the Read tool):
- /Users/egekibar/Library/Application Support/Tasker/shots/2026-09-22T0914-a1.png
  (Sipariş listesi, filtre "Son 7 gün" seçili, 3 aylık kayıtlar görünüyor)
- /Users/egekibar/Library/Application Support/Tasker/shots/2026-09-22T0915-a2.png
  (Aynı ekran, network inspector açık, /api/orders isteği görünüyor)

NOTE (dictated by the user, verbatim transcript):
"şey burada son yedi gün seçtim ama üç aylık her şeyi getiriyor,
sanırım backend'de date range parametresi hiç kullanılmıyor,
bir de boş sonuçta spinner sonsuza kadar dönüyor ona da bakılsın"

PROJECT: /Users/egekibar/Github/pazardex-backend

EXPECTED OUTCOME:
1. Find why the date range filter is ignored and fix it.
2. Fix the infinite spinner on an empty result set.
3. Add or update a test that covers the 7-day filter.
4. Do NOT touch unrelated modules. Do NOT commit or push.
```

Bunu çalıştıran komut §"Öneri"deki Swift snippet'inde.

---

## Öneri

### Entegrasyon karar tablosu

| Karar | v1 (ilk sürüm) | v2 (büyüme) |
|---|---|---|
| **Birincil kanal** | Swift `Process` → `claude -p --output-format json` | Aynı + `--input-format stream-json` ile çok turlu oturum ve gerçek base64 image block |
| **Görsel iletimi** | Prompt'ta mutlak yol + `--add-dir` (Read tool okur) | Küçük/tek görselde base64 image block, büyük batch'te yol |
| **İkinci kanal (manuel/"şimdi bak")** | `claude://code/new?q=…&folder=…&file=…` deep link; dosya eki çalışmazsa `cowork/new` fallback | Aynı + `claude://claude.ai/new?q=…` (kod tabanı gerektirmeyen sorular) |
| **Auth** | Kullanıcının mevcut claude.ai/Max login'i (API key YOK). `--bare` asla kullanılmaz. | Opsiyonel: ileri düzey kullanıcı için `ANTHROPIC_API_KEY` alanı (in-app analiz modu) |
| **İzin modu** | `--permission-mode acceptEdits --permission-prompts none` + `--max-turns 30 --max-budget-usd 2.00` | Görev tipine göre: ANALYZE ONLY → `dontAsk` + `--disallowedTools "Edit,Write,Bash"` |
| **Zamanlama** | **Hibrit:** SQLite job tablosu + `launchd` LaunchAgent (`StartCalendarInterval`) + uygulama içi `DispatchSourceTimer` + `didWakeNotification` reconcile | + Kullanıcı isterse `~/.claude/scheduled-tasks/` altına Desktop task yazma (Claude'un kendi Routines UI'ında görünsün diye) |
| **İlerleme kanalı** | `--output-format stream-json --verbose` stdout parse | + `--settings` ile `Stop`/`Notification` HTTP hook → `http://127.0.0.1:<port>` |
| **Sonuç hand-off** | Tasker içi özet kartı (`result`, `total_cost_usd`, `num_turns`) + "Terminal'de aç" + "Desktop'ta aç" (`claude://code/resume`) | + `--json-schema` ile yapılandırılmış sonuç, git diff paneli, PR linki |
| **Dağıtım** | Developer ID, **App Sandbox KAPALI** (Process spawn + Keychain gereksinimi) | Aynı — Mac App Store bu mimaride mümkün değil |
| **MCP** | Yok | Tasker yerel MCP sunucusu (Node, `stdio`) + **`.mcpb` Desktop Extension** ile tek tıkla kurulum. Tool'lar önce metadata listesi dönsün, görseli sadece istenince — `MAX_MCP_OUTPUT_TOKENS` 25k. |

### Swift `Process` çağrısı (somut)

```swift
import Foundation

struct ClaudeRunResult: Decodable {
    let type: String
    let subtype: String            // success | error_max_turns | error_during_execution | error_max_budget_usd
    let is_error: Bool
    let session_id: String
    let result: String?
    let total_cost_usd: Double?
    let num_turns: Int?
    let duration_ms: Int?
    let duration_api_ms: Int?
    let permission_denials: [PermissionDenial]?
    struct PermissionDenial: Decodable { let tool_name: String? }
}

func runClaudeTask(prompt: String,
                   projectDir: URL,
                   shotsDir: URL,
                   sessionID: UUID) async throws -> ClaudeRunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/Users/egekibar/.local/bin/claude")
    p.currentDirectoryURL = projectDir            // cwd == hedef proje
    p.arguments = [
        "-p", prompt,
        "--session-id", sessionID.uuidString,     // job ID == session ID
        "--output-format", "json",
        "--add-dir", shotsDir.path,               // screenshot klasörüne erişim
        "--permission-mode", "acceptEdits",
        "--permission-prompts", "none",           // unattended: kimse prompt cevaplamayacak
        "--max-turns", "30",
        "--max-budget-usd", "2.00",
        "--disallowedTools", "Bash(rm *)", "Bash(git push *)",
        "--append-system-prompt", Self.taskerSystemPrompt,
        "--model", "claude-sonnet-5"
    ]
    // GUI'den başlatılan process minimal env alır; PATH ve HOME'u açıkça verin.
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = NSHomeDirectory()
    env["PATH"] = "/Users/egekibar/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env.removeValue(forKey: "ANTHROPIC_API_KEY")  // abonelik login'i kullanılsın
    p.environment = env

    let out = Pipe(); let err = Pipe()
    p.standardOutput = out; p.standardError = err
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()

    guard p.terminationStatus == 0 else {
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw TaskerError.claudeFailed(code: p.terminationStatus, stderr: msg)  // 143 == SIGTERM
    }
    return try JSONDecoder().decode(ClaudeRunResult.self, from: data)
}

// Sonucu masaüstünde açmak:
func openInDesktop(sessionID: String) {
    NSWorkspace.shared.open(URL(string: "claude://code/resume?session=\(sessionID)")!)
}

// Manuel "şimdi bak" akışı — prompt composer'a dolar, kullanıcı Enter'a basar.
// route: "code/new" (proje bağlamı) veya "cowork/new" (dosya eki kesin çalışıyor).
func openInDesktopComposer(route: String, prompt: String, shots: [URL], projectDir: URL) {
    var c = URLComponents(string: "claude://\(route)")!
    var items = [URLQueryItem(name: "q", value: String(prompt.prefix(14_000)))]  // ~14k'da kırpılır
    items.append(URLQueryItem(name: "folder", value: projectDir.path))           // her seferinde onay ister
    items += shots.map { URLQueryItem(name: "file", value: $0.path) }            // mutlak yol şart
    c.queryItems = items   // URLComponents encoding'i kendi yapar
    NSWorkspace.shared.open(c.url!)
}
```

### Beklenen JSON çıktı şekli

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "duration_ms": 84213,
  "duration_api_ms": 71904,
  "num_turns": 11,
  "session_id": "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73",
  "result": "Tarih filtresi OrderQueryBuilder::applyFilters içinde dateFrom/dateTo parametrelerini hiç okumuyordu...\n\nDeğişen dosyalar:\n- app/Queries/OrderQueryBuilder.php\n- resources/js/components/OrderList.vue\n- tests/Feature/OrderFilterTest.php",
  "total_cost_usd": 0.4137,
  "usage": { "input_tokens": 41233, "output_tokens": 6180,
             "cache_read_input_tokens": 128400, "cache_creation_input_tokens": 12050 },
  "modelUsage": { "claude-sonnet-5": { "inputTokens": 41233, "outputTokens": 6180, "costUSD": 0.4137 } },
  "permission_denials": [],
  "structured_output": null,
  "uuid": "b81e4f22-1c7a-4a90-93d5-6e0f8a3c2d11"
}
```

### Uygulamaya geçmeden önce test edilmesi gerekenler

1. **GUI'den spawn edilen `claude -p` Keychain'e erişebiliyor mu?** Keychain ACL'leri imza bazlıdır; `claude` binary'si kendi ACL'ine sahip olduğu için sorun çıkmamalı ama **ilk prototipte mutlaka doğrulayın** (Tasker.app'ten spawn edip `auth status` çalıştırın).
2. **`claude://code/new?file=...` görseli gerçekten iliştiriyor mu?** Resmî doküman evet diyor, bundle kodu hayır ima ediyor (§3.3-5). `cowork/new` ile karşılaştırmalı test edin.
3. `--permission-prompts none` + `acceptEdits` kombinasyonunun tipik bir bug-fix görevini prompt'a takılmadan bitirebildiği.
4. `launchd` LaunchAgent'ın uyku sonrası kaçan `StartCalendarInterval` işini gerçekten tek sefer çalıştırdığı.

---

*Bu belgedeki CLI bayrakları, `auth status` çıktısı, transcript yol formatı, `claude://` rotaları ve parametre limitleri bu makinede doğrudan doğrulanmıştır. Doküman alıntıları code.claude.com ve platform.claude.com'dan Eylül 2026 itibarıyla alınmıştır.*
