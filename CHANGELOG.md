# Changelog

What changed in each release that someone who uses Rhino or writes scripts for it needs to know. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0, a minor version may change the script API or how data is stored; the entry says so under **Changed**.

## [Unreleased]

The first public version, 0.1.0. There is no prebuilt download yet; you build it from source.

### Added

- **Scripts as single JavaScript files**, run in JavaScriptCore with top-level `await` and no packages to install. Header tags give a script its name, description, key, schedule and watched folder.
- **A script API** for input (`input.ask`, `input.form`, `input.file`), output (logs, tables, charts, images, text, files), HTTP (`get`, `post`, `download`, `upload` and the rest), files and CSV, `shell()`, `notify()`, `memory` between runs and `secrets` in the Keychain.
- **AI in scripts**: `ai.ask()` with answers as text or as data in a shape you give, files and pictures as input, and `ai.image()`. Providers: Anthropic, OpenAI, Google, xAI, OpenRouter, Ollama, or any server that speaks the chat-completions format.
- **An AI writer** that writes a script from a description, tries it, and repairs it when it fails.
- **Chaining**: `run()` calls another script, `{ show: true }` puts what it publishes on show, and `input.from()` reads what another script last produced. New Pipeline writes such a chain from a list of steps.
- **Ways to run**: by hand, on a schedule, when a file arrives in a folder, and from the Shortcuts app.
- **History**: every run with its log, HTTP and AI calls, inputs and outputs, and earlier versions of every script.
- **Shared functions** defined once in Settings and usable in every script; folders and search for scripts.
- **Safety**: a script the AI wrote lists what it reaches for and asks before its first run; a script has to be allowed each saved secret; secrets are blanked in everything a run shows or keeps; limits on AI calls and notifications per run.
- Thirteen example scripts that run against public services.

[Unreleased]: https://github.com/bmfyfz/rhino/commits/main
