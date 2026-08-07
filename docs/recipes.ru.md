# Рецепты — вопросы и команды, которые на них отвечают

[English](recipes.md) | **Русский**

README перечисляет команды. Эта страница перечисляет **вопросы** — потому что именно они у вас и
есть, когда вы садитесь за код: не «какой флаг у `blast`», а «можно ли удалить этот тип».

Каждый блок ниже получен запуском, а не написан. Чтобы воспроизвести любой:

```bash
git clone https://github.com/Alamofire/Alamofire.git && cd Alamofire
git checkout 0455bfb
sextant index          # сборка, ~минута; семантическим ответам она нужна
```

Вывод сокращён там, где стоит `…`; остальное — дословно.

---

## Можно ли удалить этот тип?

```console
$ sextant blast Session
── blast radius: Session [class]
   a change would touch: 7 files · 25 usages · 0 calls
     Source/Alamofire.swift
     Source/Core/Session.swift
     Source/Features/AuthenticationInterceptor.swift
     …
```

Одна команда вместо грепа по имени и открывания всего, что нашлось. `blast` считает
использования, места вызова и реализации, поэтому «0 calls» у класса — это ответ, а не пробел:
у типа мест вызова не бывает. Мало — прочитайте файлы; 25 в 7 файлах — вот объём ревью.

## Что этот тип выставляет наружу?

```console
$ sextant api --type Session
# Public API  •  declarations: 51
## Source
Source/Core/Session.swift
  class Session: @unchecked Sendable  — `Session` creates and manages Alamofire's `Request` types …
    static let `default`  — Shared singleton instance used by all `AF.request` APIs …
    let session: URLSession  — Underlying `URLSession` used to create `URLSessionTasks` …
    …
```

Сигнатуры и doc-саммари, без тел — на наборе замеров это на 79–91% меньше байт, чем чтение
исходников. `--package` для целого таргета, `--scope` для подкаталога.

## Кто это вызывает на самом деле, через протокол?

```console
$ sextant callers validate
── validate(policy:errorProducer:)  [instanceMethod]
   def: Source/Features/ServerTrustEvaluation.swift:521:17  public func validate(policy: SecPolicy, …) throws {
   calls: 3 in 1 file(s)
     Source/Features/ServerTrustEvaluation.swift: 190, 624, 639
```

Вызов через протокол попадает в требование протокола, и `callers` это учитывает — через
отношение `overrideOf`, которого текстовый поиск не знает. `--full` покажет сами строки.

## Всё об одном символе одним запросом

```console
$ sextant context RetryResult
── RetryResult  [enum]
   def: Source/Features/RequestInterceptor.swift:67  public enum RetryResult: Sendable {
   usages: 17
     • Source/Core/Request.swift:1271  func retryResult(for request: Request, dueTo error: AFError, …)
     • Source/Core/Session.swift:1349  public func retryResult(for request: Request, …) {
     …
```

Определение, использования, вызывающие, вызываемые и иерархия в одном ответе. С этой команды
стоит начинать — остальные нужны, когда уже знаешь, какая половина тебе нужна.

## Кто реализует этот протокол?

```console
$ sextant impls RequestInterceptor
── RequestInterceptor: 7
   • AuthenticationInterceptor [class]  Source/Features/AuthenticationInterceptor.swift:160  …
   • OfflineRetrier [class]  Source/Features/OfflineRetrier.swift:31  …
   • DeflateRequestCompressor [struct]  Source/Features/RequestCompression.swift:39  …
   …
```

Из индекса компилятора, поэтому соответствие, объявленное в extension, тоже считается, — а то,
что записано через `where`, не теряется, как потерял бы греп по `: RequestInterceptor`.

## На чём построен этот тип?

```console
$ sextant supertypes DataRequest
── DataRequest: 2
   • Request [class]  Source/Core/DataRequest.swift:28  public class DataRequest: Request, @unchecked Sendable {
   • Sendable [protocol]  Source/Core/DataRequest.swift:28  public class DataRequest: Request, @unchecked Sendable {
```

Обратное направление к `impls`: базы и протоколы вместо реализующих.

## Каким путём вызов доходит до этой функции?

```console
$ sextant hierarchy validate --callers --depth 2
# call hierarchy (← callers, depth 2)
validate(policy:errorProducer:) [instanceMethod]  Source/Features/ServerTrustEvaluation.swift:521
  evaluate(_:forHost:) [instanceMethod]  Source/Features/ServerTrustEvaluation.swift:190
  performDefaultValidation(forHost:) [instanceMethod]  Source/Features/ServerTrustEvaluation.swift:624
    evaluate(_:forHost:) [instanceMethod]  Source/Features/ServerTrustEvaluation.swift:116
    …
```

Транзитивно, с обнаружением циклов. `--callees` идёт в другую сторону: что в итоге вызывает сама
эта функция.

## Что эта функция делает целиком?

```console
$ sextant body cURLDescription
── Source/Core/Request.swift:1179
public func cURLDescription() -> String {
        guard
            let request = lastRequest,
            let url = request.url,
            …
```

`defs` и `context` дают сигнатуру, `body` — всё объявление. Им стоит пользоваться вместо
открывания файла и прокрутки до номера строки.

## Что изменилось на ветке, символ за символом?

```console
$ sextant changed --from HEAD~5 --to HEAD
Source/Core/Request.swift
  − Request.func withState(perform: (State) -> Void)

Source/Core/Session.swift
  + Session.struct MutableState
  + Session.let mutableState
  − Session.var activeRequests: Set<Request>
```

Это не построчный дифф: объявления добавленные, удалённые и сменившие сигнатуру, с указанием
типа-владельца. Коммит с переформатированием не даст здесь ничего — в этом и смысл. То, что
сравнить не удалось (файл без флагов компиляции, неразбираемая ревизия), называется, а не
зачитывается как «без изменений».

## С чего начать чтение репозитория?

```console
$ sextant map --pagerank
# PageRank map (files by centrality)

Source/Core/AFError.swift
  enum AFError: Error, Sendable
  extension Error
  …
```

Файлы по тому, насколько остальной код от них зависит, — по графу ссылок из индекса. Обычный
`map` даёт ту же карту в порядке файлов и под token-бюджет.

## Искать форму, а не строку

```console
$ sextant search 'try! $X'
Tests/TestHelpers.swift:316:20: try! asURL()

total: 2
```

`$X` — дырка, `$$$` поглощает любое число аргументов. Совпадение структурное, поэтому `try!`
внутри комментария или строки им не является. Objective-C, C и C++ идут через clang и требуют
флагов от `sextant index`; всё, что прочитать не удалось, называется, а не зачитывается как
«совпадений нет».

## Работает ли моя установка вообще?

```console
$ sextant doctor
# sextant doctor — …/scratchpad/alamofire
✅ Swift sources: 59 files
✅ libIndexStore: …/usr/lib/libIndexStore.dylib
✅ index store: .build/x86_64-apple-macosx/debug/index/store
✅ index opened: 1 store(s)

✅ ready — `sextant mcp` will work (semantics and structure)
```

С неё стоит начинать, когда ответ выглядит неправильным. Она говорит, какой индекс найден,
свежий ли он и чего не хватает, — в том числе не запускается ли на самом деле другой `sextant`
из вашего `PATH`.

---

## Как эта страница остаётся честной

Каждый блок здесь получен запуском команды по Alamofire на коммите `0455bfb`. Вывод меняется
вместе с инструментом, а документация, расходящаяся с ним молча, хуже, чем её отсутствие, —
поэтому перезапуск этих команд перед релизом входит в чек-лист
[RELEASING.ru.md](../RELEASING.ru.md#1-подготовить-версию). Когда вывод сдвинулся — обновите
блоки, а если сдвинулся пакет, то и коммит.
