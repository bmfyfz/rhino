# Writing scripts

A script is one JavaScript file of plain top-level code. It reads from `input`, does its work, and writes to `output`. This guide covers what you need to write one by hand.

The full reference is [`globals.d.ts`](../RhinoCore/Sources/RhinoCore/Resources/globals.d.ts): TypeScript declarations of every global, with comments and examples. The app shows the same file under Help > Script API Reference. This guide does not repeat all of it.

## Where scripts live

Scripts are `.js` files in `~/Library/Application Support/Rhino/Scripts`. "Show in Finder" in a script's context menu takes you there. You can edit them in Rhino or in any other editor; Rhino picks up changes made elsewhere when it becomes the active app, unless its own editor has unsaved changes.

Scripts can be kept in folders inside the scripts folder. A script's id is its path below that folder without `.js`: `fetch-users`, or `reports/monthly` for one in a folder. Everything a script remembers, its versions and its run history are kept under that id; when you move a script in the app, they move with it. Moving the file in Finder gives it a new id and leaves them behind.

## The shape of a script

```js
// @name Fetch users
// @description Lists the users in a team

const team = await input.ask("Which team?", { default: "core" });
const res = await get("https://api.example.com/users", { query: { team } });

output.log(`Got ${res.data.length} users`);
output.json(res.data).name(`Users in ${team}`);
```

- No wrapper function and no `export`. The code runs top to bottom, in strict mode.
- Top-level `await` works. Everything that touches the outside world returns a Promise, so `await` it.
- `return` at the top level ends the script early.
- Throwing an Error fails the run. Rhino shows the message and the line.
- Let failures throw. A failed HTTP call already throws with a clear message. Add `try`/`catch` only where the script can do something useful about the failure.

## Header tags

The header is the block of `//` comments at the top of the file. It ends at the first line that is not a comment. Each tag is one line: `// @tag value`. All tags are optional.

| Tag | What it does |
| --- | --- |
| `@name` | The name shown in the app. Without it, the file name is used. |
| `@description` | One line about what the script does. |
| `@key` | A keyboard shortcut that runs the script while Rhino is the active app. |
| `@schedule` | Runs the script by itself at the given times. |
| `@watch` | Runs the script when a file arrives in a folder. |

### `@key`

```js
// @key cmd+shift+u
```

One key, plus at least one of `cmd`, `ctrl` or `opt` (`shift` may be added). A shortcut without one of those three is ignored, so a script can never swallow plain typing.

### `@schedule`

```js
// @schedule every 15 minutes
// @schedule every 2 hours
// @schedule hourly
// @schedule every day at 09:00
// @schedule daily at 9am, 5:30pm
// @schedule weekdays at 09:00
// @schedule weekends at noon
// @schedule mon, thu at 18:30
// @schedule mon-fri at 9:00
// @schedule 0 9 * * 1-5
```

Use one `@schedule` line per script. The last form is a cron expression: minute, hour, day of month, month, day of week.

- Times are in the Mac's time zone.
- "Every N minutes" must divide an hour evenly (1, 2, 3, 4, 5, 6, 10, 12, 15, 20 or 30). "Every N hours" must divide a day evenly (1, 2, 3, 4, 6, 8 or 12).
- Scheduled scripts only run while Rhino is open. Closing the window keeps it running; quitting stops them.
- If the Mac was asleep when a run was due, the script runs once when it wakes, however many runs it missed.
- If the previous run is still going when the next one is due, the new one is skipped.
- If a schedule cannot be read, the app marks the script and says why.
- A scheduled run that fails posts a notification.

### `@watch`

```js
// @watch ~/Downloads
// @watch ~/Documents/Invoices/*.pdf
```

The value is a full path, starting with `/` or `~`. The last part may be a file name pattern with `*` and `?`; without one, every file counts. The pattern is matched without regard to case.

- The file that arrived is what `input.file()` returns.
- Files that were already in the folder do not start a run. Hidden files and unfinished downloads (`.download`, `.crdownload`, `.part`, `.partial`, `.tmp`) are ignored.
- Rhino waits until a new file has stopped growing before it starts the run.
- Several files run one after another, one file per run.
- Like schedules, folders are only watched while Rhino is open, and "Pause Schedules" pauses them too.

## Input

Ask for what the script needs rather than hard-coding it.

One value:

```js
const team = await input.ask("Which team?");
const count = await input.ask("How many?", { type: "number", default: 10 });
const format = await input.ask("Format?", { options: ["csv", "json"], default: "csv" });
const sure = await input.confirm("Delete the old export?", { default: false });
```

Several values at once, with one form:

```js
const { from, format, dryRun } = await input.form(
  {
    from: { label: "Start date", type: "date" },
    format: { options: ["csv", "json"], default: "csv" },
    dryRun: { default: true },
  },
  { title: "Export", submit: "Export" }
);
```

A field's type is worked out from its default when you leave it out: options make a select, a boolean a toggle, a number a number field. The other types are `textarea`, `secret`, `date`, `datetime`, `time` and `file`.

Files:

```js
const orders = await input.file("Orders export", { ext: "csv" });
const rows = await orders.csv();
```

`input.file()` hands out the files that were dropped on the script, one per call. When none is left, or none has the wanted extension, it asks the user to pick one. A file has `name`, `path`, `ext` and `size`, and the methods `text()`, `json()` and `csv()`. `input.files` is the list of every dropped file.

`input.data` is what the caller passed: the second argument of `run(name, data)`, or the Input of the Shortcuts action. It is `null` when the user started the script directly.

## Output

Logging:

```js
output.log("Fetched", rows.length, "rows");
output.warn("No rows for March");
```

`console.log`, `console.warn` and `console.error` do the same.

Publishing results. Each call shows up in the app at once. Give each one a name that says what it is:

```js
output.table(orders, { columns: ["id", "customer", "total"] }).name("Open orders");
output.chart(sales, { type: "line", x: "month", y: ["online", "stores"] }).name("Sales by channel");
output.image("https://example.com/logo.png").name("Logo");
output.text(`**${total} units** sold in six months.`).name("Summary");
output.json(users).name("Active users");
```

- `output.table()` takes objects (keys become columns) or arrays of cells.
- `output.chart()` types are `bar` (the default), `line`, `area`, `point` and `pie`.
- `output.image()` takes a web address, a file path, a file, a `data:` URL, or SVG markup. SVG is how a script draws something of its own.
- `output.text()` understands Markdown emphasis: bold, italic, code and links.
- `output.json()` publishes a value. The last one is also the script's result: what `run()` returns to a calling script and what the Shortcuts action gives back. It must be JSON-serializable.

Saving a file as an output of the run:

```js
const path = await output.file("export.csv", csv.stringify(rows)).name("Orders in March");
```

A plain name goes into the run's own folder under `Runs/`. Objects are written as pretty JSON.

## HTTP

```js
const res = await get("https://api.example.com/users", {
  query: { team: "core" },
  headers: { Authorization: `Bearer ${token}` },
});
output.log(res.status, res.data.length);

await post("https://api.example.com/users", { name: "Ada" });
```

- `get`, `post`, `put`, `patch` and `del` return a response with `status`, `ok`, `url`, `headers` (lowercase names), `text`, and `data`. `data` is the parsed JSON when the body is JSON, otherwise the same string as `text`.
- An object or array body is sent as JSON, a string as it is, and a file as its bytes.
- A status outside 2xx throws an Error with `.status` and `.response`. Pass `{ throwOnError: false }` to look at the response yourself.
- `timeout` is in milliseconds.
- Only `http:` and `https:` addresses work.

Anything that is not text or JSON is a download:

```js
const logo = await download("https://example.com/logo.png").name("Logo");
output.image(logo.path);
```

Sending a form with files:

```js
const picture = await input.file();
await upload("https://api.example.com/photos", { title: "Receipt", photo: picture });
```

Every call is recorded with the run: method, address, headers, bodies, status and time. You can look at them in the run's log.

## Files and CSV

```js
const text = await read("~/Documents/notes.txt");
await write("~/Desktop/summary.txt", "Done");

if (await file.exists("~/Desktop/old.csv")) {
  output.log(await file.list("~/Desktop"));
}
```

Absolute paths and `~/` are used as they are. A relative path points into the run's own folder. For files the user gave the script use `input.file()`, and for results use `output.file()`.

```js
const rows = csv.parse(text);                       // objects keyed by the header row
const table = csv.parse(text, { header: false });   // arrays of strings
const out = csv.stringify(rows, { columns: ["id", "total"] });
```

All parsed values are strings. The delimiter is detected from the first line unless you give one.

## Secrets

Never put a password, API key or token in the source.

```js
const token = await secrets.get("GITHUB_TOKEN", "A GitHub personal access token");
const res = await get(url, { headers: { Authorization: `Bearer ${token}` } });
```

The first time, the user is asked for the value and it is saved in the Keychain. After that it is returned without asking. The same name is the same secret in every script, so name it for what it is, in capitals. Secrets can also be added and removed in Settings > Secrets.

A script gets a saved secret without a question only if the user typed it in for that script. When another script asks for the same name, the user is asked once whether that script may use it; saying no fails the call with an error. Settings > Secrets shows which scripts use each secret.

A value from `secrets.get()` is blanked in everything the run shows or keeps: the log, recorded HTTP and AI calls, errors, published values, names and notifications. It is not blanked in files the script writes, so do not put it there.

## Memory

```js
const seen = await memory.get("seenIds", []);
const fresh = items.filter((item) => !seen.includes(item.id));
await memory.set("seenIds", [...seen, ...fresh.map((item) => item.id)]);
```

Each script has its own memory, kept between runs. Values are anything JSON can hold. There are also `memory.delete(key)` and `memory.keys()`. "Clear Memory" in a script's context menu makes it forget everything.

## AI

`ai.ask()` sends a prompt to the provider and model chosen in Settings > AI.

```js
const summary = await ai.ask(`Summarise in two sentences:\n\n${text}`);
```

With `returns`, the answer comes back as data in the shape you describe:

```js
const rows = await ai.ask(`Extract every invoice:\n\n${text}`, {
  returns: [{ number: "string", total: "number", paid: "boolean" }],
});

const { sentiment } = await ai.ask(`Review: ${text}`, {
  returns: { sentiment: ai.oneOf("positive", "neutral", "negative") },
});
```

A shape is `"string"`, `"number"`, `"integer"` or `"boolean"` for a value, `[shape]` for a list, `{ key: shape }` for an object, and `ai.oneOf(...)` for a fixed choice.

Files can go along with the question: pictures (PNG, JPEG, GIF, WebP), PDFs and text files, up to 20 MB each.

```js
const invoice = await input.file();
const { total, due } = await ai.ask("Read this invoice.", {
  files: [invoice],
  returns: { total: "number", due: "string" },
});
```

Other options are `system`, `provider`, `model`, `effort` and `maxTokens`.

`ai.image()` makes a picture and saves it with the run's files. It needs a provider that makes pictures; Anthropic does not.

```js
const cover = await ai.image("A watercolour of a lighthouse at dawn").name("Cover");
output.image(cover.path);
```

Things to know:

- The model sees only what is in the prompt and the files. Put the text or data in it.
- Each call costs the user money and takes seconds. Ask about many items in one call, not once per item.
- It fails if no provider is set up.

## Chaining scripts

```js
const stats = await run("repo-stats", { repo: "swiftlang/swift" });
```

Functions of your own can be shared by every script. Define them in Settings → Functions, or as `.js` files in the `Functions` folder beside `Scripts`:

```js
// Turns a date into "5 March 2026". The AI writer reads this comment too.
function longDate(date) {
  return new Date(date).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
}
```

What a file declares at the start of a line (`function`, `const`, `class`) can be used in any script by name, like `get` or `output`. A shared function can use the built-in API, and what it logs or fetches counts as the calling script's doing. A name can be defined only once, and not one the API already has.

What a script started with `run()` publishes (tables, charts, files) stays with it, like a function's local work. Pass `{ show: true }` to put it on show in the calling run. Scripts run one after another this way, each handed the result of the one before as its `input.data`, make a pipeline:

```js
const orders = await run("Fetch orders", input.data, { show: true });
const clean = await run("Clean orders", orders, { show: true });
return await run("Build report", clean, { show: true });
```

A pipeline is an ordinary script, so it can have a schedule, a watched folder and a key, and anything can go between two steps: a filter, an `if`, a loop, two scripts at once with `Promise.all`. A step that fails stops it, and the error names that script and the line. Only a script that is on show itself can put another on show. File → New Pipeline… writes such a script for you from a list of steps.

`input.from()` reads what another script produced the last time it ran successfully, without running it again:

```js
const figures = await input.from("Monthly sales").file("The figures");
const totals = await input.from("Monthly sales").output("Totals");
const rates = (await input.from("Rates", { maxAge: 3600_000 }))?.result ?? await run("Rates");
```

`.file()`, `.output()` and `.result()` fail with a message saying what is missing when the script has not run yet. Awaiting `input.from()` itself gives the whole run, or null.

`run()` runs another script and returns its result: the last value it gave to `output.json()`. The name is the other script's `@name`, its id (`reports/monthly`), or its file name alone if no other script shares it. The second argument shows up there as `input.data`. The other script sees the same dropped files. If it fails, `run()` throws.

A chained script's published outputs are not shown to the user; only the script that was started publishes. Its log lines and calls are shown.

## Shell commands

`shell()` runs a command with zsh, as you would type it in Terminal, and gives back what it printed:

```js
const branch = (await shell("git branch --show-current", { cwd: "~/code/site" })).text;
const pdfs = (await shell("ls ~/Downloads/*.pdf", { throwOnError: false })).lines;
await shell("pbcopy", { input: "copied by a script" });
```

The result has `stdout`, `stderr`, `text` (the output without its last line break), `lines`, `code` and `ok`. A command that fails throws with what it printed, unless `throwOnError` is false. Options: `cwd`, `input`, `timeout` in milliseconds, and `env`.

A command can change or delete anything you can. Never put text from a file, a web page or an AI's answer into a command without checking it.

## Notifications and waiting

```js
notify("Backup finished", `${files.length} files copied`);
await sleep(2000);
```

`notify()` shows a notification on the Mac. Clicking it opens the run. Use it for what is worth interrupting someone for; progress belongs in `output.log()`.

## Unattended runs

A run started by a schedule, a watched folder or the Shortcuts app has nobody to answer questions. Then:

- `input.ask()` and `input.confirm()` resolve to their default. Without a default, the run fails.
- `input.form()` resolves to its fields' defaults. A required field without a default fails the run.
- `input.file()` returns a file the run was given: the file that arrived in the watched folder, or the Files of the Shortcuts action. If there is none, the run fails.
- `secrets.get()` returns a saved secret the script has been allowed. If the secret is not saved yet, or the script has not been allowed it, the run fails and says so. Run the script once by hand to be asked.

So in a script meant to run unattended:

- give every question a default,
- get keys and tokens from `secrets.get()`, and run the script once by hand first,
- use `memory` to act only on what is new since the last run,
- call `notify()` when there is something the user should hear about.

## Limits

- Only the globals in `globals.d.ts` and standard JavaScript built-ins exist. There is no `import`, `require`, `fetch`, `setTimeout` or other timer, no npm packages, and no Node or browser API. Use `run()` to call another script, the HTTP functions for requests, and `sleep()` to wait.
- A run may call the AI 25 times by default, counting `ai.ask()` and `ai.image()` together and including chained scripts. The next call fails. The user can raise the limit in Settings > AI.
- At most 10 notifications are shown per run, including chained scripts. Further `notify()` calls are dropped, with a warning in the log.
- `run()` may nest at most 32 levels deep.
- Files sent to `ai.ask()` may be up to 20 MB each.
- `write()` and `output.file()` cannot write into Rhino's own folders (`Scripts`, `Functions`, `Memory`, `Versions`).
- `shell()` works on the Mac only.
- Rhino does not start a script that is still running. A scheduled run that comes due meanwhile is skipped, files arriving in a watched folder wait their turn, and the Shortcuts action reports that the script is busy. Calling the same script several times with `run()` is fine.

## Examples

Rhino writes a set of example scripts into the scripts folder on first launch. Each runs as it is and shows a part of the API doing something useful. Their source is in [`Resources/Examples`](../RhinoCore/Sources/RhinoCore/Resources/Examples) in the core package.

| Script | What it shows |
|---|---|
| Weather outlook | A form, two HTTP calls (Open-Meteo), a chart, a table and a summary. |
| GitHub repository | Parallel requests, a pie chart, and taking input from another script. |
| Hacker News top stories | Many requests at once, and `memory` to tell what is new since the last run. |
| Earthquakes today | A public feed (USGS) as a table and chart, and `notify` for the rare big one. |
| Currency rates | A month of ECB rates (Frankfurter) as a line chart. |
| Picture of the day | `download()` and `output.image()` with Wikipedia's featured picture. |
| Site check | Uptime checks with `memory` and `notify`; meant to be given a schedule. |
| CSV report | A dropped file as a table, a chart and a saved JSON file. Needs no network. |
| Mac status | `shell()`: disk space, battery and uptime. |
| AI / Sort feedback | `ai.ask()` with `returns`, so the answer comes back as data. |
| AI / Summarise stories | `input.from()` to build on another script's last result, then `ai.ask()`. |
| Pipelines / News digest | `run()` twice in a row with `{ show: true }`: fetch the front page, then summarise it. |
| Pipelines / Compare repositories | `run()` with data, twice in parallel, and a CSV file. |
