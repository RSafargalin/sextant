# sextant

[![CI](https://github.com/RSafargalin/sextant/actions/workflows/ci.yml/badge.svg)](https://github.com/RSafargalin/sextant/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/RSafargalin/sextant?sort=semver)](https://github.com/RSafargalin/sextant/releases/latest)
[![Licence](https://img.shields.io/badge/licence-Apache--2.0-blue)](LICENSE)
[![Swift](https://img.shields.io/badge/swift-6.2%2B-orange)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](#установка)

[English](README.md) | **Русский**

Code intelligence для локальных Swift-проектов: карта репозитория, структурный поиск (замена
grep) и семантика — где определён символ, кто его использует, что пакет выставляет наружу.
Смысл — дать LLM-агенту точный доступ к коду по запросу вместо grep: ответы точнее, токенов
меньше.

Переиспользуемый по замыслу: работает по корню любого проекта, а не вшит в один.

## Как это выглядит

Один вопрос — один ответ, вместо цикла «grep и прочитать пять файлов». Оба запуска ниже —
sextant по собственному репозиторию; списки сокращены там, где стоит `…`, остальное —
дословно:

```console
$ sextant context ProjectConfig
[index: spm · 1 store(s) · fresh]
── ProjectConfig  [struct]
   def: Sources/SextantCore/ProjectConfig.swift:4  public struct ProjectConfig: Codable, Sendable {
   usages: 12
     • Sources/SextantCore/ProjectConfig.swift:21  case loaded(ProjectConfig)
     • Sources/sextant/IndexCommands.swift:47  switch ProjectConfig.read(projectRoot: root) {
     • Sources/sextant/MCPServer.swift:63  switch ProjectConfig.read(projectRoot: project) {
     • Sources/sextant/main.swift:41  func loadConfig(_ arguments: [String]) -> ProjectConfig? {
     …
   bases and protocols: Sendable

$ sextant blast SourceLocation
[index: spm · 1 store(s) · fresh]
── blast radius: SourceLocation [struct]
   a change would touch: 9 files · 37 usages · 0 calls
     Sources/SextantCore/BlastRadius.swift
     Sources/SextantCore/IndexStore.swift
     Sources/SextantCore/SymbolContext.swift
     …
```

С `--json` тот же ответ приходит структурой — для агента. Эти же запросы выставлены в Claude
Code как MCP-инструменты, см. [MCP](#mcp--подключение-к-claude-code).

## Языки

Семантические команды (`refs`, `defs`, `callers`, `context`, `blast`, `hierarchy`, …) читают
index store компилятора, а его пишет всё clang-семейство. Поэтому они работают по **Swift,
Objective-C, C и C++**, в том числе через языковую границу: вызов из Swift, записанный как
`greet(withName:)`, находится как caller селектора Objective-C `greetWithName:`, который он и
вызывает.

`map` и `api` покрывают те же четыре языка: не-свифтовые объявления они читают из индекса, а не
вторым парсером, — поэтому для этого им нужен собранный индекс.

**Только по Swift** остаётся всё, что разбирает текст исходника: `search`, `lint`, `changed` и
`construct`. Текста исходника в индексе нет, так что тут нужен парсер на каждый язык — это
[ADR-0004](docs/adr/0004-structural-layer-for-c-family.md), и он ещё не сделан. Пока его нет,
эти команды называют то, что пропустили, вместо ответа как будто пропущенного не было:
`changed` перечисляет файлы C, C++ и Objective-C, которые не сравнивал.

## Сколько это экономит

Замерено на пяти публичных Swift-пакетах (Alamofire, swift-argument-parser, swift-numerics,
swift-nio, swift-syntax) на закреплённых ревизиях. Полные числа и команды, которыми это можно
перепроверить самому, — в [docs/benchmarks.ru.md](docs/benchmarks.ru.md):

| Задача | Экономия против чтения исходников |
|---|---|
| Узнать публичную поверхность пакета | **79–91%** |
| Узнать один тип, включая все его extension'ы | **83–95%** |
| Повторный запрос по неизменному дереву | до **112×** быстрее (кэш по content-hash) |

Единица — байты вывода: они воспроизводятся точно, тогда как число токенов зависит от
токенизатора. Сравнение верно для задачи «понять поверхность», а не «понять реализацию»:
`api` отдаёт сигнатуры и doc-саммари, но не тела. Для тел есть `body`.

## Статус

Рабочий CLI и MCP-сервер, версия 0.7.x. 23 команды:

| Команда | Что делает | Слой |
|---|---|---|
| `map` | карта репозитория под token-бюджет; `--semantic` — типы по числу использований; `--pagerank` — файлы по центральности | синтаксис / семантика |
| `api` | публичная поверхность пакета (атрибуты, doc-саммари) | синтаксис |
| `search <pattern>` | структурный поиск по AST (`$X`, вариадик `$$$`, statement-паттерны); Swift, непросмотренные не-Swift файлы называются | синтаксис |
| `lint` | структурные правила гигиены (`--rules <json>`); Swift, непросмотренные не-Swift файлы называются | синтаксис |
| `refs` / `defs` / `callers` | использования / определение / места вызова (callers учитывают протокол-диспетчеризацию) | семантика |
| `callees` | что вызывает символ (best-effort: вызовы внутри проекта) | семантика |
| `impls` / `supertypes` | реализации и подтипы, базы и протоколы типа | семантика |
| `hierarchy <symbol>` | транзитивный граф вызовов (`--callees` / `--callers`, `--depth N`) | семантика |
| `context <symbol>` | сводка одним запросом: определение, использования, вызывающие, вызываемые, иерархия | семантика |
| `blast <symbol>` | импакт-анализ: что затронет изменение символа | семантика |
| `body <symbol>` | полный текст объявления (сигнатура и тело) | семантика + синтаксис |
| `construct <type>` | места конструирования и инъекции (эвристика `Type(`) | эвристика |
| `changed` | символьный git-дифф: что добавлено, удалено, сменило сигнатуру (Swift; остальные языки перечисляются как несравнённые) | синтаксис |
| `golden` / `bench` | регрессии семантики по спеке / латентность и объём вывода | измеримость |
| `mcp` | MCP-сервер (stdio) для Claude Code — семантический слой как инструменты | интеграция |
| `init` | настроить проект: `.sextant.json`, регистрация в `.mcp.json` и проверка | интеграция |
| `serve` | демон с тёплым индексом: холодный старт CLI 2.6с → 0.27с (замер на самом sextant) | интеграция |
| `doctor` | самопроверка setup'а (исходники, libIndexStore, index store, свежесть) | диагностика |
| `index` | собрать index store: SPM (`swift build`) или app-таргет (`--app`, xcodebuild) | сборка |

Общие флаги, каждый — у тех команд, где он осмыслен: `--project <путь>` (у всех), `--json`
(структурный вывод, у всех команд-запросов), `--reindex` (пересобрать индекс перед запросом),
`--scope <подкаталог>` и `--max-files <N>` (`map`, `api`, `search`, `lint`). Точный набор —
`sextant <команда> --help`. Дефолты берутся из `.sextant.json`. `.gitignore` уважается:
полностью под git и только по именам каталогов вне его.

## Установка

Три пути; Swift-тулчейн нужен только третьему.

**1. Homebrew (tap)** — рекомендуемый:

```bash
brew tap RSafargalin/tap
brew trust RSafargalin/tap
brew install sextant
sextant --version
```

Homebrew отказывается загружать формулы из недоверенного стороннего tap'а, поэтому `brew trust`
обязателен — это разовое подтверждение того, что вы ставите из чьего-то личного tap'а, а не из
homebrew-core.

**2. Готовый бинарь из релиза** — macOS universal (arm64 + x86_64), без Homebrew:

```bash
V=0.7.0
curl -fsSL -O "https://github.com/RSafargalin/sextant/releases/download/v$V/sextant-$V-macos-universal.tar.gz"
shasum -a 256 "sextant-$V-macos-universal.tar.gz"   # сверьте с sha256 в теле релиза
tar -xzf "sextant-$V-macos-universal.tar.gz"
xattr -d com.apple.quarantine sextant || true       # снять карантин (отсутствие атрибута — не ошибка)
mkdir -p ~/.local/bin && install -m 0755 sextant ~/.local/bin/sextant
```

Бинарь **не подписан и не нотаризован** (сертификата разработчика нет). При скачивании через
браузер Gatekeeper вешает атрибут карантина и блокирует первый запуск; снимается командой
`xattr -d com.apple.quarantine sextant`. Загрузки через `curl` и Homebrew карантином не
помечаются, но команда безвредна в любом случае.

**3. Сборка из исходников** — нужен Swift 6.2+:

```bash
swift build && swift test
make ci                       # сборка + тесты + self-lint
make install                  # release-бинарь в ~/.local/bin (добавьте его в PATH)
swift run sextant help
swift run sextant map --project <path>
```

### Что нужно семантическому слою

Синтаксические команды (`map`, `api`, `search`, `lint`, `changed`) работают на голой системе.
Семантическим (`refs`, `defs`, `callers`, `callees`, `impls`, `supertypes`, `hierarchy`,
`context`, `blast`, `body`) нужен **Xcode-тулчейн**: `libIndexStore.dylib` ищется через
`xcrun --find swiftc`, а index store производит `swift build` или `xcodebuild`. Проверить
setup — `sextant doctor --project <path>`: чеклист с actionable-подсказками о том, чего не
хватает.

## Демон (ускорение CLI)

Каждый запуск CLI платит за открытие index store — на выросшем сторе это около 2.6с, и платит
его **каждый** суб-агент. Демон держит индекс открытым:

```bash
sextant serve --project /путь/к/проекту &   # в фоне, по одному на проект
```

Клиенты используют его автоматически; если демон не запущен, они идут обычным путём — это не
ошибка. `SEXTANT_NO_DAEMON=1` полностью отключает обращение к демону. Сборку и setup (`index`,
`init`, `doctor`) демон не выполняет никогда — они запускают чужой код и пишут в проект.

Замер на самом sextant (стор 53 МБ, одинаковое состояние): `refs` **2.6с → 0.27с**, примерно
10×. На небольшом свежесобранном сторе разница меньше: переиспользование БД между запусками и
так даёт ~0.3с.

## MCP — подключение к Claude Code

`sextant mcp` — stdio MCP-сервер (JSON-RPC 2.0). Индекс открывается один раз при старте и
переиспользуется, поэтому тёплый запрос стоит ~0.2с против холодного shell-out. За свежесть
отвечают `listenToUnitEvents` и опрос перед каждым запросом: индекс, собранный по ходу сессии,
подхватывается без перезапуска сервера. 13 инструментов:

`context`, `blast_radius`, `body`, `who_defines`, `find_references`, `find_callers`,
`list_implementations`, `call_hierarchy`, `repo_map`, `structural_search`, `lint`,
`api` (публичная поверхность пакета или типа — на порядок дешевле чтения файлов) и `changed`
(символьный git-дифф).

Инструменты уважают `.sextant.json` (budget, scope, rules) ровно так же, как CLI. Список
инструментов в `initialize` генерируется из контракта, поэтому не может разойтись с
фактическим набором.

Проще всего — одна команда в корне проекта. Она создаст `.sextant.json`, зарегистрирует сервер
в `.mcp.json` (уже прописанные там серверы сохраняются) и скажет, что делать дальше:

```bash
sextant init
```

Вручную, через клиента (после `make install` бинарь лежит в `~/.local/bin/sextant`):

```bash
claude mcp add sextant -- ~/.local/bin/sextant mcp --project /путь/к/проекту
```

Либо `.mcp.json` в корне проекта:

```json
{
  "mcpServers": {
    "sextant": {
      "command": "/абсолютный/путь/к/sextant",
      "args": ["mcp", "--project", "/путь/к/проекту"]
    }
  }
}
```

Семантическим инструментам нужен index store — соберите его заранее (`sextant index` или
`index --app`). Без индекса сервер всё равно стартует, `repo_map` работает, а семантические
инструменты возвращают подсказку, а не неверный ответ.

Перед регистрацией проверьте setup: `sextant doctor --project <path>` — чеклист (исходники,
libIndexStore, index store и его свежесть) с подсказками, что собрать.

## Архитектура

| Слой | Назначение | Технология | Статус |
|---|---|---|---|
| L1 repo-map | символьная карта под token-бюджет | SwiftSyntax | ✅ |
| L2 structural | структурный поиск и правила, замена grep | свой движок (SwiftSyntax) | ✅ |
| L3 semantic | defs / refs / callers / public API | IndexStoreDB | ✅ |
| L3+ semantic | callees / иерархия типов / транзитивный call-hierarchy / PageRank-карта | IndexStoreDB relations | ✅ |
| L4 MCP | команды как инструменты для агента (stdio JSON-RPC, тёплый индекс) | MCP (stdio) | ✅ |
| L5 | другие языки в структурном слое, мёртвый код, real-time | — | ⬜ не-цель v1 |

**Не-цели v1:** real-time file-watcher, vector search, структурный слой для не-Swift. Это осознанные
вырезы, а не недосмотр; часть из них запланирована на поздние итерации в
[docs/roadmap.ru.md](docs/roadmap.ru.md). Архитектурные решения в `docs/adr/` — на русском:
это историческая запись того, как инструмент дошёл до текущего состояния.

## Участие в разработке

[CONTRIBUTING.ru.md](CONTRIBUTING.ru.md) — как собрать и чего ждут от изменений.
[AGENTS.md](AGENTS.md) — инварианты, которые не видны из исходников (на английском: файл
читают агенты).

## Лицензия

Apache License 2.0 — см. [LICENSE](LICENSE). Та же лицензия, что у Swift и swift-syntax, на
которых инструмент построен.
