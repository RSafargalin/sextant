# ADR-0002: MCP-поверхность — на что опираемся, что игнорируем

- **Статус:** Принято
- **Дата:** 2026-06-29
- **Автор:** Руслан Сафаргалин
- **Связано:** `docs/adr/0001-evolution-to-production-maturity.md` (фичи, которым нужна MCP-опора)

## Контекст

sextant как MCP-сервер использует малую часть протокола: `tools` (9 штук) + `initialize`/`ping`,
а `resources/list` и `prompts/list` заглушены пустыми. Многие фичи из ADR-0001 (зона памяти,
context-compiler, громкая stale-деградация, intent-поиск) предполагали опору на другие
примитивы MCP. **Фича бесполезна, если клиент её не чтит, или если примитив уходит из спеки.**

Доступность перепроверена по **первичным источникам** (офиц. док Claude Code + спека MCP +
SEP), а не по GitHub-issues — issue-based отчёт оказался смещён к багам и устарел (ошибочно
объявил `list_changed` и `roots` неподдерживаемыми, хотя док Claude Code их документирует).

Два независимых факта определяют решение:
1. **Поддержка в Claude Code** (что чтит клиент сегодня).
2. **Направление спеки:** RC 2026-07-28 (SEP-2577) **деприкейтит Roots, Sampling, Logging**
   (рунвей ≥12 мес, MCP идёт в stateless); SEP-2322 (Multi Round-Trip Requests) заменяет
   server-initiated вызовы (sampling/elicitation) на stateless-паттерн `InputRequiredResult`.
   В **текущей стабильной** спеке 2025-06-18 sampling ещё НЕ деприкейтнут.

## Решение

Опираться только на примитивы, которые **и поддержаны Claude Code, и переживут stateless-переход**.
Не вкладываться в server-initiated/stateful примитивы под деприкейтом.

### Матрица: примитив × поддержка Claude Code × статус спеки × применение в sextant

| Примитив | Claude Code | Спека (RC 2026-07-28) | Решение для sextant |
|---|---|---|---|
| **Tools** | ✅ надёжно | стабильно | Ядро. `outputSchema` держать простым (без `$defs` — мисматч → невидимый результат) |
| **Resources** + templates + completion | ✅ `@`-mentions, `@server:protocol://path`, fuzzy, авто-attach, авто-tools list/read | стабильно | **Опора.** Offload зоны памяти (хэндлы вместо блобов), context-packs, карты фич |
| **`list_changed`** (tools/prompts/resources) | ✅ авто-refresh capabilities | стабильно | Динамическое обновление списка ресурсов работает (per-resource `subscribe` доком не подтверждён) |
| **Prompts** (slash-команды) | ✅ `/mcp__sextant__*` | стабильно | Adoption-канал против grep-привычки. ⚠️ **без required-аргументов** (issue: не элиситятся, таймаут) |
| **Elicitation** | ✅ документирована (form-mode + `Elicitation` hook) | ⚠️ мигрирует в SEP-2322 | Интерактив: «индекс устарел — пересобрать?», дизамбигуация, подтверждение рефактора. **Обернуть в абстракцию** под будущую миграцию |
| **`CLAUDE_PROJECT_DIR`** (env var) | ✅ Claude Code кладёт корень проекта в окружение сервера | n/a (не примитив MCP) | **Чистый фикс резолва проекта** — лучше cwd и лучше `roots/list`, не под деприкейтом |
| **Roots** (`roots/list`) | ✅ возвращает launch-каталог | ❌ **деприкейт SEP-2577** | Не использовать — предпочесть `CLAUDE_PROJECT_DIR` |
| **Sampling** | ❌ не поддержан (issue #1785) | ❌ **деприкейт SEP-2577** | **Мёртв.** «AI через модель хоста» отменяется. Нужна модель → свой Anthropic API |
| **Logging** (`notifications/message`) | ⚠️ ненадёжно (теряются) | ❌ **деприкейт SEP-2577** | Не использовать. Provenance → in-band в вывод tool/ресурса |
| **Pagination** | ⚠️ issue: только первая страница | стабильно | Списки держать < ~100; у sextant 9 tools → не горит |
| **Progress / Cancellation** | ⚠️ часть ссылок про Claude Desktop; есть `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` | стабильно | Не полагаться на продление таймаута прогрессом |

### Design-constraint: долгие операции — не inline-tool

Сборка индекса (`index --app`) на проекте A заняла **510с (8.5 мин)** — дольше типового
idle-таймаута MCP-tool. **Сборка не должна быть inline-tool-call’ом.** MCP только *читает*
готовый индекс; пересборка — CLI/фон. При stale через MCP: `elicitation` «запустить
пересборку?» + немедленный возврат, без блокирующего ожидания.

### Правила (что строить / чего не строить)

**Строим на:** Tools, Resources (+ templates, completion, list_changed), Prompts (без
required-args), Elicitation (через абстракцию), `CLAUDE_PROJECT_DIR`.

**НЕ строим на:** Sampling, Roots, Logging notifications (все три под деприкейтом + слабая/нулевая
поддержка). Замены: intent-поиск/ранжирование → свой Anthropic API или офлайн-эмбеддинги;
резолв проекта → `CLAUDE_PROJECT_DIR`; provenance → in-band; live-свежесть → in-band staleness
+ elicitation.

## Последствия

- **Плюсы.** `CLAUDE_PROJECT_DIR` снимает проблему `--project`/cwd и worktree-резолва начисто.
  `list_changed` оживляет динамические ресурсы. Зона памяти и context-packs получают
  поддержанную опору (Resources).
- **Риски.** Elicitation мигрирует в SEP-2322 — интерактивность изолировать за абстракцией,
  чтобы пережить переход. Stateless-направление MCP означает: не закладывать stateful-зависимости
  от сервера к клиенту.
- **Урок процесса.** Проверять доступность по первичным источникам (док клиента + спека + SEP),
  не по GitHub-issues; разделять Claude Code и Claude Desktop.

## Гейт

- **Г-MCP:** перед реализацией любой фичи, опирающейся на MCP-примитив, сверить по этой матрице;
  на Sampling/Roots/Logging — не реализовывать.
