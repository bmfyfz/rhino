# Contributing

Thanks for wanting to help. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first: it explains the two layers and how a run works, and the rest of this file assumes it.

## Setup

You need macOS 27, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Rhino.xcodeproj
```

`Rhino.xcodeproj` is generated from `project.yml` and is not checked in. Run `xcodegen generate` again after you add, move or delete files in `App/`, or change `project.yml`.

Run the package's tests (the engine, and the `rhino` tool against a stand-in app) from the command line:

```sh
cd RhinoCore && swift test
```

Things to know while developing:

- A build from Xcode uses the same data as an installed copy: `~/Library/Application Support/Rhino` and the same Keychain entries. Do not run two copies at once. Both would run the schedules and write to the same history.
- Builds from Xcode are signed ad hoc, so macOS may ask again for access to Rhino's Keychain items after a rebuild. `Tools/install.sh` signs with a real identity to avoid that.
- If no Anthropic key is saved, the app uses `ANTHROPIC_API_KEY` from the environment. `ANTHROPIC_BASE_URL` points the Anthropic provider at another address, such as a local stand-in. Both only apply when the app is started with them set, for example from a terminal.

## Where things go

- If it can work without a window, the Keychain or the app's settings, it belongs in `RhinoCore`, with a test.
- If it needs AppKit, SwiftUI, SwiftData, the Keychain, notifications or App Intents, it belongs in `App`.
- When the core needs something only the app can provide, add a protocol in the core and implement it in the app, as `SecretStore`, `MemoryStore`, `AIProvider` and `ScriptProvider` do.
- `RhinoCore` has no third-party dependencies. Please keep it that way unless there is a strong reason. The command line tool (`RhinoCLI`) uses Swift Argument Parser, and nothing else in the package does.
- What the `rhino` tool and the app say to each other is in `RhinoControl`. A new command is a case in `ControlRequest`, an answer in `ControlService` (app), a command in `RhinoCLI`, a test in `RhinoCLITests`, and a row in [docs/CLI.md](docs/CLI.md).

## Conventions

These describe the code as it is. New code should read the same way.

**Swift 6 with strict concurrency.** The package and the app both build in the Swift 6 language mode. The app target uses `MainActor` as its default isolation; the core does not. Types that cross isolation boundaries are `Sendable`. All access to a JavaScript context stays on its run's serial queue. The few `nonisolated(unsafe)` values in the engine each have a comment saying why they are safe; do not add one without the same.

**Comments explain why, not what.** A doc comment says what a type or function is for in a sentence or two. A comment inside a function is there because the code alone would not tell you the reason: a provider's quirk, an ordering that matters, a case that looks wrong but is not. Do not narrate what the next line does.

**User-facing text is plain language.** Error messages, labels and log lines are read by people who may never look at the code. Say what happened and what to do about it, in ordinary words: "Add an API key for OpenAI in Settings to use AI.", not a status code or a type name. This applies to errors thrown from the core as well, since they reach the user unchanged. The comments in `globals.d.ts` are user-facing text too.

**Tests use swift-testing and never touch the network.** Suites are `@Suite` structs with `@Test` functions and `#expect`, one suite per file in `RhinoCore/Tests/RhinoCoreTests/`. Shared helpers are in `Support/`:

- `makeEngine(_:)` builds an engine over a dictionary of script sources, with its own temporary runs folder.
- `Recorder` collects every `RunEvent` of a run and answers prompts from a closure.
- `StubProtocol` is a `URLProtocol` that answers every request inside the test process. It stands in for plain HTTP endpoints, Anthropic's Messages API, chat completions, model lists and image generation. `stubbedSession()` returns a `URLSession` that uses it.
- `TestAI` is an `AIProvider` over services that talk to the stub.

A test that needs a new kind of response adds it to the stub. No test may reach a real server or need a real key.

**Limits protect the user.** Anything a script can do in a loop that costs money or attention has a cap in the engine. Keep that in mind when adding to the API.

## Adding to the script API

Every global a script can use exists in four places, and a change to the API touches all of them:

1. **`Resources/prelude.js`**: the JavaScript side. Add the function to the object `makeAPI` returns. Check arguments here and throw errors that say how to call it correctly. If it needs native work, go through `call("operationName", runId, args)`, which returns a Promise.
2. **The engine, in `Runtime/`**: the native side. Register the host function in `install(on:)`, normally with `operation("operationName") { … }`. Follow the existing operations: `register` the callback, do the work, `settle` with a value or an error message.
3. **`Resources/globals.d.ts`**: the declaration, with a comment and a short example. This file is the reference people read in the app and the reference the AI writer is given, so write it for both.
4. **A test** in `RhinoCoreTests` that runs a script using the new API through `makeEngine`.

A new top-level name (as opposed to a new method on `input`, `output` and so on) must also be added to `ScriptCompiler.globals`. The script wrapper takes its parameters from that list, and the syntax tokenizer uses it to colour built-ins.

Things to get right on the native side:

- **Unattended runs.** If the new API asks the user anything, decide what it does when `interactive` is false: use a default, or fail with a message that says what is missing.
- **Secrets.** Pass anything that will be recorded or shown (log lines, span URLs, headers, bodies, notification text) through `masked`.
- **Cancellation.** Long work runs in a task stored in `tasks`, so that cancelling the run cancels it.
- **Paths.** Use `resolve(path:)`: absolute and `~` paths as given, relative paths into the run's output folder.
- **Events.** If the app should show something new, add a `RunEvent` case, handle it in `RunSession.apply`, and add a `RunRecord.Item` case if it should survive in the history.

If the new API changes how scripts should be written, update the instructions in `ScriptWriter.systemPrompt` and consider adding an example to `Examples`: the writer learns the style from both. Update [docs/WRITING-SCRIPTS.md](docs/WRITING-SCRIPTS.md) as well.

## Adding an AI provider preset

Most providers offer OpenAI's chat-completions format. For those, a preset is one entry in `AIProviderSetup.presets` in `App/Model/AISettings.swift`:

```swift
Preset(
    setup: AIProviderSetup(id: "example", name: "Example", api: .openAI, address: "https://api.example.com/v1", model: "", requiresKey: true, isCustom: false),
    summary: "One line for the list", keyPage: URL(string: "https://example.com/keys"), aliases: ["example-alias"]
),
```

- `id` is permanent. The key's Keychain entry and the saved settings are stored under it.
- `address` is the part before `/chat/completions`.
- Leave `model` empty. Model names change too often to guess; the user picks one with "Load Models".
- `aliases` are other names a script may pass as `provider`. They must not clash with another provider's name, id or aliases.
- `requiresKey: false` is for servers that take no key, such as a model running on the Mac.

Then check that it works against the real service: "Load Models" lists chat models, `ai.ask()` answers, and `ai.ask()` with `returns` comes back as data. If the provider deviates from the format, handle that in `OpenAIClient` or `AIService` with a comment that says which provider needs it, and add a case to the stub and a test.

A provider that speaks neither wire format needs more: a new case in `AIService.API`, a client next to `ClaudeClient` and `OpenAIClient` in `AI/`, request bodies for questions, structured output and the writer, stub responses, tests, and the format picker in Settings.

## Pull requests

- Keep a pull request to one change. Say what it does and why in the description.
- `cd RhinoCore && swift test` passes, and the app builds.
- A change to the core comes with a test. A bug fix comes with a test that fails without the fix.
- A change to the script API updates `globals.d.ts` and, where it matters, `docs/WRITING-SCRIPTS.md`.
- Do not commit `Rhino.xcodeproj`, build output, API keys or anything from your own `Application Support/Rhino` folder.
- Changes to the app's UI are easier to review with a screenshot.

For a larger change, open an issue first to agree on the approach.

Security problems are reported privately; see [SECURITY.md](SECURITY.md).

Contributions are released under the [MIT licence](LICENSE), like the rest of the project.
