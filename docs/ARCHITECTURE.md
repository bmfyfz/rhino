# Architecture

Rhino has two layers: `RhinoCore`, a Swift package that knows how to run scripts, and `App`, the SwiftUI app around it. Beside them is the `rhino` command line tool, which asks the running app to do things and prints the answers.

## Two layers

`RhinoCore` contains everything that does not depend on a screen or on one platform's services: storing and compiling scripts, the engine, the AI clients, parsing schedules and watched folders, the syntax tokenizer. It imports Foundation, JavaScriptCore, Synchronization and UniformTypeIdentifiers, and nothing from AppKit or SwiftUI. Its `Package.swift` declares macOS and iOS. The reason for the split is reuse: an app on another platform, or a command-line tool, can run the same scripts without taking the Mac app with it. It is also what makes the core testable with `swift test` and no app running.

`App` owns what is specific to this Mac app: the windows, the Keychain, the run history in SwiftData, notifications, the Shortcuts action, the scheduler loop and the folder watcher.

The core never reaches for those services itself. It defines protocols, and the app supplies implementations when it creates the engine:

| Protocol (core) | What it is for | The app's implementation | In tests |
| --- | --- | --- | --- |
| `ScriptProvider` | Finds a script's source by id or name | `ScriptStore` (also in core: a folder of `.js` files) | A dictionary of sources |
| `SecretStore` | `secrets.get()` | `KeychainSecretStore` | `InMemorySecretStore` |
| `SecretGrants` | Which script may read which saved secret | `FileSecretGrants` (in core: one JSON file) | `InMemorySecretGrants` |
| `MemoryStore` | `memory` | `FileMemoryStore` (in core: one JSON file per script) | `InMemoryMemoryStore` |
| `AIProvider` | `ai.ask()` and `ai.image()` | `ConfiguredAI`, which picks a provider from Settings | `TestAI` |

## Layout

```
RhinoCore/
  Sources/RhinoCore/
    Scripts/     ScriptStore, ScriptCompiler, ScriptVersions, ScriptSearch,
                 ScriptFootprint (what a script reaches for), SharedLibrary
    Runtime/     Engine and its capabilities, run events and records, forms,
                 rich outputs, the secret and memory stores
    AI/          AIService, the Anthropic and OpenAI-compatible clients, ScriptWriter
    Triggers/    Schedule, FolderWatch
    Editing/     SyntaxTokenizer, Reindenter, LineDiff
    Resources/   prelude.js, globals.d.ts, Examples/ (the example scripts, as .js files)
  Sources/RhinoControl/   what the app and the rhino tool say to each other, and
                          the socket they say it over. No dependencies.
  Sources/RhinoCLI/       the rhino tool: its commands and what they print
  Sources/rhino/          the tool as the package builds it (`swift run rhino`)
  Tests/RhinoCoreTests/   one file per suite, plus Support/
  Tests/RhinoControlTests/, Tests/RhinoCLITests/
App/
  Model/      AppModel, RunSession, AISettings, RunHistory, FolderWatcher
  Control/    ControlService: answers the rhino tool
  Views/
  Settings/
  Support/    Keychain, Shortcuts, syntax theme
  Assets.xcassets
Tool/         the rhino tool as the Xcode project builds it, to put it in the app
Tools/
  install.sh  builds a release, signs it, installs it in /Applications
project.yml   the XcodeGen description of the app and the tool
```

## How a run works

1. Something starts a run: the user, a schedule, a watched folder or a shortcut. `AppModel` creates a `RunSession` and calls `Engine.run(_:files:data:interactive:maxAICalls:events:)`. The app starts a script only when no earlier run of it is still going.

2. `Engine` creates one `Execution` for the run. `Execution` is an actor whose executor is its own serial dispatch queue. It creates a new `JSVirtualMachine` and `JSContext`, so top-level runs never share JavaScript state. Every touch of the context happens on that queue. JavaScriptCore calls host functions synchronously while a script runs, so those calls are already on the actor's queue and enter it with `assumeIsolated`.

3. `Execution` installs the host functions on one `host` object. A few are synchronous: `beginRun`, `load`, `endRun`, `output`, `nameOutput`, `nameFile`, `log`, `notify`. The rest are operations that take `(runID, arguments, callback)` and call back later: `http`, `download`, `readFile`, `writeFile`, `fileExists`, `listDirectory`, `sleep`, `ask`, `form`, `secret`, `memory`, `ai`, `aiImage`.

4. `prelude.js` is evaluated once in the context. It receives `host` and returns `start`. For each script it runs, the prelude builds a fresh copy of the API bound to that run's id (`makeAPI`), so logs, calls and questions are attributed to the right script even when chained scripts run at the same time. Most of the API's behaviour lives here in JavaScript: argument checking, CSV, turning `returns` into a JSON Schema, shaping chart and table data. The native side does only what JavaScript cannot.

5. To load a script, `host.load` asks the `ScriptProvider` for the source and passes it to `ScriptCompiler.wrap`. The compiler rejects `import` and `export` with a message that says what to do instead, then wraps the source in an async function that receives the globals as parameters. That is what makes top-level `await` and an early `return` work. The wrapper starts on the script's first line, so line numbers in errors match the file. The script is evaluated under the source URL `rhino:///<id>.js`.

6. A call such as `await get(url)` goes through the prelude's `call(op, runId, args)`. It returns a Promise and hands a callback to the host function. The native side keeps the callback in a table of pending operations, does the work in a task, and settles the callback back on the actor. The prelude captures an `Error` at the call site first, so a failure that arrives later still reports the script's own line.

7. `run("other")` inside a script runs the other script in the same context, as a child run with its own id and its own API copy. Only the script that was started from outside publishes outputs. In a chained script, `output.json()` is what `run()` returns to the caller. Nesting deeper than 32 levels fails.

8. As the run goes on, `Execution` reports `RunEvent` values: `runStarted`, `runFinished`, `log`, `spanStarted` and `spanFinished` (HTTP and AI calls), `file`, `output`, `prompt`, `promptResolved`, `notification`. They are delivered in order on a background queue. The app passes them through an `AsyncStream` to the main actor, where `RunSession.apply` updates what the window shows.

9. A question (`input.ask`, `input.form`, `input.file`, or `secrets.get` for a secret that is not saved yet or that the script has not been allowed) is a `.prompt` event with a `PromptRequest`. The request has a `reply` closure, which is called exactly once with the answer. When `interactive` is false nobody can answer: a question resolves to its default, or fails the run if it has none. Every run that the user did not start by hand is non-interactive.

10. Cancelling the task that called `Engine.run` cancels the run. Pending operations fail with "Run cancelled", so the script unwinds through its own error handling.

11. When the script's Promise settles, the run ends and `Engine.run` returns a `RunSummary`: the error if any, the result as JSON, the output folder and the times. An error is a `RunError` with the script and line, read from the first stack frame inside a script.

12. The app turns the finished `RunSession` into a `RunRecord` (core, `Codable`): everything the run logged, called, asked, wrote and published, in order. `RunHistory` stores the encoded record.

## The command line tool

`rhino` is a separate program that does nothing by itself. The package has three pieces for it:

- `RhinoControl` is the conversation: `ControlRequest`, `ControlMessage` and the types the answers are made of, plus `ControlListener` and `ControlClient`, which carry them over a Unix socket as one JSON value per line. It depends on nothing, and both the app and the tool link it.
- `RhinoCLI` is the tool: its commands, built with Swift Argument Parser, and `Render`, which turns answers into text. `Session` finds the app, opens it when it is not running, and turns failures into a message and an exit code.
- `rhino` is two lines that call `RhinoCommand.main()`. The Xcode project builds the same two lines from `Tool/` and copies the result to `Rhino.app/Contents/Helpers/rhino`.

In the app, `AppModel` starts a `ControlListener` when the setting is on. Each connection carries one request, which `ControlService` answers on the main actor by calling the model: the same functions the window uses, plus a few that end in `FromCommandLine`. A run goes through `runFromCommandLine`, which asks for approval when the script's footprint has something not yet agreed to, starts the run with the trigger `.commandLine`, and passes its events on. `ControlService` sends each event to the tool as a `RunLine` while the run goes, and the whole `RunReport` at the end. When the tool's connection closes early, the task is cancelled, which withdraws the question or stops the run.

The app never trusts the tool with more than a person at the window has, and with less in two places: it cannot answer an approval, and no request touches a secret's value.

## The AI layer

The same layer serves `ai.ask()` and `ai.image()` inside scripts, and the writer that produces scripts.

**AIService.** One `AIService` is one provider ready to use: a name, a wire format, a base address, a key and a model. There are two wire formats, and they cover every provider the app knows:

- `.anthropic`: Anthropic's Messages API, in `ClaudeClient`.
- `.openAI`: chat completions as OpenAI defined them, in `OpenAIClient`. Google, xAI, OpenRouter and Ollama are reached this way, each at its own address.

An `AIService` can answer a question (`answer`), write a long text as a stream (`write`, used by the writer), make a picture (`picture`, only for the OpenAI format), and list the models a key can use (`models`, used by Settings).

**Structured output.** `ai.ask(prompt, { returns })` takes the shape of the answer written as an example, such as `{ total: "number", tags: ["string"] }`. The prelude turns it into a JSON Schema. The schema's top level must be an object, so any other shape travels inside `{ value: … }` and is taken out again. `AIService` sends the schema in the form each wire format has for it: `output_config.format` for Anthropic, `response_format` with a strict `json_schema` for chat completions. The prelude parses the reply, so the script gets data, not text. A script can pass a full JSON Schema with `schema` instead.

**Errors.** Failures become an `AIError` with a reason (`missingKey`, `missingModel`, `api`, `refused`, `truncated`, `empty`, `unsupported`) and a message written for the person using the app. Providers name their errors differently, so the OpenAI client maps HTTP statuses onto one set of kinds.

**From the engine's side.** The engine knows only the `AIProvider` protocol. In the app, `ConfiguredAI` resolves the provider a question names (by name, id or alias) or the one chosen for scripts, builds the `AIService` with its key from the Keychain, and asks it. Each call is recorded as a span, like an HTTP call, with the prompt, the answer, the model and the token counts. `ai.ask()` and `ai.image()` count toward one limit per run, 25 by default.

**ScriptWriter.** The writer sends one request per job, with no conversation. A job is `write` (a new script from a description), `revise` (a change to a script) or `fix` (a script whose run failed, with the failure). The system prompt is fixed: instructions, the whole of `globals.d.ts`, and the example scripts. It is the same for every request, which lets a provider cache it. The reply is the script's source and nothing else, and it streams into the editor.

The loop around the writer is in `AppModel`: write, check the syntax with `ScriptCompiler.syntaxProblem`, then, if "Try scripts after writing them" is on, run the script. If that fails, the error and the last log lines go back as a `fix` job, at most twice.

**Provider presets.** The list of known providers (name, wire format, address, where to get a key, aliases) is `AIProviderSetup.presets` in the app's `AISettings`. Only the Anthropic preset comes with a model; for the others the user picks one from what the provider lists.

## Triggers

A script's header says how it runs. `ScriptHeader.parse` reads the tags, and the core has a parser for each kind. The app does the waiting.

- **Key.** `Shortcut` (core) parses `// @key`. The app lists every script in its Run menu with that shortcut, which is what makes the key work.
- **Schedule.** `Schedule` (core) parses `// @schedule`, a phrase or a cron expression, into rules, and answers one question: the next time after a given date. `AppModel` keeps the next time for each scheduled script and runs a loop that sleeps for at most 20 seconds at a time, so a Mac that was asleep is noticed quickly. A script whose time passed during sleep runs once. A script that is still running when its time comes is skipped.
- **Folder.** `FolderWatch` (core) parses `// @watch` into a folder and an optional file name pattern, and decides whether a file counts. The app's `FolderWatcher` watches each folder with a dispatch source, compares the file names with those it saw before, and waits until a new file has stopped growing. Then the script runs once per file, in the order the files came.
- **Shortcuts.** `RunScriptIntent` is the "Run Script" action. It runs the script with optional input and files, and returns the script's result as text.

"Pause Schedules" stops both scheduled and folder-triggered runs. A run started by a schedule or a folder that fails posts a notification.

## Persistence

Everything is under `~/Library/Application Support/Rhino`.

| What | Where | Owner |
| --- | --- | --- |
| Scripts | `Scripts/<id>.js` | `ScriptStore` (core) |
| Files a run saved | `Runs/<time>-<script>-<suffix>/` | `Engine` (core) |
| Script memory | `Memory/<script>.json` | `FileMemoryStore` (core) |
| Script versions | `Versions/<script>/`, one JSON file per version, 100 kept | `ScriptVersions` (core) |
| Run history | `History.store`, SwiftData, 50 runs kept per script | `RunHistory` (app) |
| Script secrets | Keychain, service `app.rhino.Rhino.secrets` | `KeychainSecretStore` (app) |
| Which script may use which secret | `SecretAccess.json`, names only | `FileSecretGrants` (core) |
| AI provider keys | Keychain, service `app.rhino.Rhino` | `APIKeyStore` (app) |
| Provider list and other settings | The app's preferences | `AISettings`, `AppModel` (app) |

Scripts, memory and versions are plain files on purpose: they can be read, backed up, kept in git or deleted like any other file. A history row holds a few columns for listing and pruning, and the encoded `RunRecord` in external storage, which is read only when a run is put back on screen.

Request and response bodies are cut to 512 KB while a run is on screen and to 64 KB when the record is stored.

## Design rules

These are visible throughout the code and worth keeping.

- **Protocols at the boundary.** The engine takes `ScriptProvider`, `SecretStore`, `SecretGrants`, `MemoryStore` and `AIProvider`. It has in-memory defaults for secrets and memory, and no AI unless one is given. Nothing in the core knows about the Keychain or the app's settings.
- **Secrets stay out of what is recorded.** Every value a run gets from `secrets.get()` is remembered for that run and blanked out of log lines, recorded URLs, headers and bodies, recorded AI prompts and answers, and notification text. Values shorter than four characters are left alone. The request itself is sent as written. The app keeps API keys and secrets in the Keychain and never writes them to files or preferences.
- **`globals.d.ts` is the one API reference.** The same file is shown in the app (Help > Script API Reference), given to the AI writer as its reference, and linked from these docs. If the API changes, that file changes.
- **One context per top-level run, on one queue.** No JavaScript state crosses runs, and no JavaScript value crosses queues.
- **Unattended by default.** `Engine.run` is non-interactive unless told otherwise. A run with nobody there uses defaults, or fails with a message that says what was missing.
- **Limits on what costs money or attention.** A run has a cap on AI calls (`Engine.defaultMaxAICalls`, changeable in Settings) and on notifications (`Engine.maxNotifications`).
- **Errors are written for the person using the app.** Error text says what happened and what to do, in plain words, and points at the script's own line where there is one.
- **Events out, no UI in.** The core reports what happened as `RunEvent` values and `Codable` records. How they are shown is the app's business.
