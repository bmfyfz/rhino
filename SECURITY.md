# Security

## Reporting a problem

Please do not open a public issue for a security problem. Report it privately: on the repository's **Security** tab, choose **Report a vulnerability**. That opens a private advisory only the maintainers can read.

Say what you found, how to reproduce it, and which version or commit you used.

Worth reporting:

- A secret from `secrets.get()` or an AI provider key that ends up in a log, a recorded call, the run history, a file or the app's preferences without the script putting it there.
- A key or secret sent to a host other than the one the user or the script chose.
- A script that runs when nothing asked for it: not the user, a schedule, a watched folder, the Shortcuts app, or the AI writer with trying turned on.
- A way for content from outside (an HTTP response, a file, an AI answer) to be run as code without the script doing so itself.
- A problem in `Tools/install.sh` or the build that could install or run something unintended.

Not a vulnerability, because it is how Rhino works (see below):

- A script can read and write your files and make network requests.
- A script you allowed to use a secret can send it anywhere.
- A script that runs commands with `shell()` can get around what Rhino itself checks.

## Trust model

Read this before you run a script you did not write.

**Scripts are code, and they run with your privileges.** The app is not sandboxed. A script can read any file your user account can, write files (`write`, `output.file`), send any HTTP request (`get`, `post`, `upload` and the rest), send data to an AI provider, and run any command with `shell()`. Rhino does not ask for confirmation before a script you run does these things. Treat a script from someone else like any script from the internet: read it first.

**What scripts cannot do.** A script runs in JavaScriptCore with only the globals in `globals.d.ts`. There is no `import`, `require`, `fetch` or Node API. `write()` and `output.file()` refuse to write into Rhino's own folders (the scripts, the shared functions, memory, versions and the history), so a script cannot quietly rewrite another one that way. Each run started from outside gets a fresh JavaScript context. None of this is a sandbox: `shell()` runs any command, and a command can do anything you can.

**A script has to be allowed each saved secret.** `secrets.get("NAME")` hands a saved secret to the script the user typed it in for. Any other script, one you just installed or one the AI just wrote, makes Rhino ask "Allow … to use your saved secret …?" first; the answer on offer is no, and a yes is remembered for that script. A run nobody is watching (a schedule, a folder, a shortcut) is never asked and does not get the secret. Settings > Secrets lists which scripts may use each secret and lets you take one back. A secret that is not saved yet is asked for by name, with a description the script wrote. Two limits: once a script has a secret it can send it anywhere, and the list of who may use what is an ordinary file in Rhino's folder (`SecretAccess.json`, names only), which a script that runs `shell()` commands could edit.

**Triggers run scripts while nobody is watching.** A script with `// @schedule` or `// @watch` runs by itself while Rhino is open. A `.js` file placed in the scripts folder with such a header runs without anyone pressing Run. Anything that can write to `~/Library/Application Support/Rhino/Scripts` can therefore run code as you; this is the same trust you give the rest of your home folder.

**AI-written scripts ask before they first run.** The AI writer produces JavaScript from a description. With "Try scripts after writing them" on, in Settings > AI (the default), Rhino runs the script once it is written, and repairs and reruns it if it fails, up to two repairs. Before that first run Rhino reads the code and, unless the script only asks, computes and shows, lists what it reaches for: the hosts it contacts, whether it sends data out, the files it writes, the commands it runs, the secrets it uses. It runs only if you agree, and you are asked again only when a later change adds something new. Agreeing also allows the script the saved secrets the list named. The list is read from the code, so it shows what the script says it does; an address or command the script puts together while running is listed as such, not resolved. Running a script by hand counts as agreeing to it as it stands, except for saved secrets, which are always asked about. Turn the setting off to read every script before it runs.

**AI answers are data.** `ai.ask()` returns text or JSON to the script. Rhino does not run an answer as code. What the script then does with it is up to the script.

## Keys and secrets

- API keys for AI providers and the secrets scripts use are kept in the Mac's Keychain. Rhino does not write them to files or preferences.
- A provider's key is sent only to the address of that provider. For the built-in providers that take a key, the address is fixed in the code. For a provider you add yourself, it is the address you enter. Requests go straight from your Mac to the provider.
- Two environment variables change this for Anthropic when Rhino is started with them set: `ANTHROPIC_API_KEY` is used when no key is saved, and `ANTHROPIC_BASE_URL` replaces Anthropic's address, so the key goes there.
- Values from `secrets.get()` are blanked out of the run's log, recorded HTTP and AI calls, and notifications. Values shorter than four characters are not. This protects against accidents, not against a script that wants to leak: a script can still publish a secret as an output, write it to a file, or send it in a request.
- A secret is sent wherever the script sends it. Rhino does not tie a secret to a host.

## What leaves your Mac

- HTTP requests a script makes go to the addresses in the script.
- `ai.ask()` sends the prompt, and any files passed to it, to the chosen provider. `ai.image()` sends the description.
- The AI writer sends your description, the script's current source, and after a failed run the error and the last log lines, to the provider chosen for writing.
- "Load Models" in Settings asks a provider which models the key can use.
- A picture a script publishes by web address is fetched from that address to show it.

## Stored data

Run history keeps log lines, requests and responses (cut to 64 KB each), questions and answers, and published values in `~/Library/Application Support/Rhino/History.store`. Files a run saved are in `Runs/`. These are not encrypted beyond what your disk is.

The answer to `input.ask()` with type `"secret"`, and the value of a `secret` field in `input.form()`, are stored with the run as dots, and from then on are blanked wherever the run shows or keeps them, like a value from `secrets.get()`. For a key or token, use `secrets.get()`: it is saved, so you are asked only once.
