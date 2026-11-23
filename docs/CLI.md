# The `rhino` command line tool

`rhino` manages and runs the scripts in the Rhino app from a terminal. It is for you, for shell scripts, and for coding agents such as Claude Code or Codex that should write and run Rhino scripts for you.

The tool does no work of its own. Each command asks the running app, which does the work with the engine, the history and the Keychain it already has. So a run started from a terminal shows up in the window like any other, and the app's rules about approval and secrets apply to it.

## Setting it up

1. In Rhino, open **Settings > General** and turn on **Allow the rhino command line tool**. It is off until you do: it lets other programs on your Mac run scripts.
2. Press **Install** beside it. That links the tool, which is inside the app, into `/usr/local/bin`, `/opt/homebrew/bin` or `~/.local/bin`, whichever can be written first.

Without the link the tool is at `/Applications/Rhino.app/Contents/Helpers/rhino`.

If Rhino is not open when you run a command, the tool opens it in the background and waits for it.

## Commands

A script is named by its id (`reports/monthly`), by its title (`"Monthly report"`), or by its file name when no other script shares it.

| Command | What it does |
| --- | --- |
| `rhino list` | The scripts: name, id, schedule or watched folder, last run. Also `rhino ls`. |
| `rhino show SCRIPT` | Prints a script's source. Also `rhino cat`. |
| `rhino api` | Prints the reference of everything a script can use. Read it before writing a script. |
| `rhino new NAME [FILE] [--folder F]` | Creates a script from a file, from what is piped in, or from the template. |
| `rhino write SCRIPT [FILE]` | Replaces a script's source, from a file or from what is piped in. |
| `rhino check [FILE] [--script S]` | Reads code without running it: is it valid JavaScript, and what would it touch? |
| `rhino run SCRIPT` | Runs a script and waits for it. See below. |
| `rhino stop SCRIPT` | Stops a running script. |
| `rhino runs [SCRIPT] [--limit N]` | Earlier runs, newest first. |
| `rhino log SCRIPT` or `rhino log RUN-ID` | One run: its log, its calls, what it returned. A script's name means its latest run. |
| `rhino mv SCRIPT FOLDER` | Moves a script into a folder; `/` is the top. |
| `rhino rm SCRIPT` | Moves a script to the Trash. |
| `rhino open [SCRIPT]` | Brings Rhino to the front, showing the script. |
| `rhino status` | What Rhino is doing: running scripts, schedules, watched folders. |
| `rhino schedules`, `rhino schedules pause`, `rhino schedules resume` | Shows every schedule, or pauses and resumes them all. |
| `rhino functions`, `functions show NAME`, `functions write NAME [FILE]`, `functions rm NAME` | The shared functions every script can use. |
| `rhino secrets` | The saved secrets by name, and which scripts may use each. Never their values. |

Every command has `--help`, and `rhino --version` prints the version.

`rhino write` and `rhino new` refuse source that is not valid JavaScript, and nothing changes. What `write` replaces is kept in the script's version history in the app.

A script's schedule, watched folder and key are lines in its header (`// @schedule every day at 09:00`), so they are changed with `rhino write`.

## Running a script

```sh
rhino run "Site check"
rhino run github-repository --data '{"repo":"swiftlang/swift"}'
rhino run csv-report --file ~/Downloads/orders.csv
```

- `--data JSON` is what the script finds in `input.data`. `--data -` reads it from standard input, and `--data-file FILE` from a file.
- `--file PATH` hands the script a file, which it gets from `input.file()`. Repeat it for several.
- What the script returned is printed as JSON on standard output. Its log goes to standard error as it happens, so `rhino run x > result.json` keeps only the result.
- `--quiet` leaves out the log. `--json` prints one document instead, with the result, the error, what was published, the files that were saved, and the log.
- Control-C stops the run.

Nobody is at the window during such a run, so the script's questions take their defaults, as they do on a schedule. A question without a default fails the run and says so. Hand the script what it needs with `--data` and `--file`.

## Output for programs

Add `--json` to any command that prints something. The JSON has stable key names, keys in alphabetical order, and dates in ISO 8601.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | It worked. |
| 1 | It did not: the script failed, the name is unknown, the source is not valid, or you said no in the app. |
| 2 | Rhino could not be reached: it is not installed, or the tool is not turned on in Settings. |
| 64 | The command was not written correctly. |

A failure prints one line on standard error that starts with `rhino:`.

Shell completion comes from the tool itself, for example `rhino --generate-completion-script zsh`.

## What needs you

Three things can only be done by a person, in the app's window:

- **Approving a script.** The first time a script is run from the command line, and whenever it starts reaching for something new (a host, a file outside its run folder, a shell command, a saved secret, the AI), Rhino shows what it reaches for and asks. `rhino run` waits for your answer and says so. `rhino check --script S` shows beforehand what has not been agreed to. Running a script by hand in the app is the same yes.
- **Scripts that run by themselves.** A script written with `rhino new` or `rhino write` does not start on its schedule, for a new file or from Shortcuts while it reaches for something you have not agreed to. Rhino tells you once, with a notification.
- **Secrets.** No command reads a secret's value, saves one, or allows a script to use one. A script that needs a secret it has not been allowed fails and says to run it once by hand.

These rules are about what goes through the tool. They are not a sandbox; [SECURITY.md](../SECURITY.md) says what that means.

## For coding agents

[skills/rhino/SKILL.md](../skills/rhino/SKILL.md) teaches an agent the tool in a page. For Claude Code, copy the `skills/rhino` folder to `~/.claude/skills/`. For other agents, point them at that file, or at `rhino --help` and `rhino api`.

## How it talks to the app

The app listens on a Unix socket, `~/Library/Application Support/Rhino/control.sock`, that only your user account can open. There is no network port. Each command is one connection: the tool sends one request as a line of JSON, and the app answers with lines of JSON, the last of which is the result or the reason it failed. Closing the connection early, which is what Control-C does, stops the run it was waiting for. The format is in `RhinoCore/Sources/RhinoControl/ControlProtocol.swift`; it is private to the tool and the app and changes with them, so build on the tool's `--json` output, not on the socket.
