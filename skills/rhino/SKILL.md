---
name: rhino
description: Write, check and run automation scripts in the Rhino Mac app with the `rhino` command line tool. Use when the user wants a small script that runs on their Mac (fetch something, chart it, summarise it, check it on a schedule) and has Rhino, or asks to list, change or run their Rhino scripts.
---

# Rhino scripts from the command line

Rhino is a Mac app that runs single-file JavaScript scripts. The `rhino` tool controls it. Every command talks to the running app; the app is started if needed.

If a command fails with exit code 2, the tool is not turned on. Ask the user to open Rhino > Settings > General and turn on "Allow the rhino command line tool". Do not try to turn it on yourself.

## Before writing a script

1. Run `rhino api`. It prints the whole script API with examples. Scripts can only use what is declared there: there is no `fetch`, `require`, `import` or npm package, and top-level `await` works.
2. Run `rhino list` to see what exists, and `rhino show SCRIPT` to read one as a model.

## Writing

```sh
rhino check draft.js                 # valid JavaScript? what would it touch?
rhino new "Site check" draft.js      # create; add --folder reports to file it
rhino write "Site check" draft.js    # replace an existing script's source
```

Source can also be piped in (`cat draft.js | rhino write "Site check"`). Invalid JavaScript is refused and nothing changes.

A script starts with a header, and may schedule itself there:

```js
// @name Site check
// @description Checks that websites answer
// @schedule every 15 minutes
```

Add `@schedule` or `@watch` only when the user asked for it.

## Running

```sh
rhino run "Site check"
rhino run github-repository --data '{"repo":"swiftlang/swift"}' --file in.csv
```

- The script's result is JSON on standard output; its log is on standard error. Exit code 0 means it finished, 1 means it failed and the last line says why.
- `--json` gives one document with `result`, `error`, `outputs`, `files` and `log`.
- Nobody answers the script's questions during such a run: `input.ask()` takes its default or fails. Pass what the script needs as `--data` (it reads `input.data`) and `--file` (it reads `input.file()`), and give every question in a script you write a default.
- `rhino log SCRIPT` shows the latest run again; `rhino runs` lists earlier ones.

## What only the user can do

- **Approve a script.** The first run of a script from the command line, and any run after it starts reaching for something new, makes Rhino ask the user in its window. `rhino run` prints "Waiting for you to approve…" and waits. Tell the user to look at Rhino; do not retry or work around it. If they say no, the command exits with 1.
- **Secrets.** Scripts get keys with `secrets.get("NAME", "what it is")`. You cannot read, save or allow a secret. If a run fails because a secret is missing or not allowed, ask the user to run the script once by hand in Rhino.

Never put a key or token in a script's source.

## Other commands

`rhino status`, `rhino stop SCRIPT`, `rhino mv SCRIPT FOLDER`, `rhino rm SCRIPT` (to the Trash), `rhino open SCRIPT`, `rhino schedules [pause|resume]`, `rhino functions` (shared functions), `rhino secrets` (names only). Each has `--help`, and most take `--json`.
