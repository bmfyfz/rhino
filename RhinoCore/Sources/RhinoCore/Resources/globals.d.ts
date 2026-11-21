/**
 * Rhino script API.
 *
 * A script is one .js file of plain top-level code. It starts with an optional
 * header, reads from `input` and writes to `output`:
 *
 *   // @name Fetch users
 *   // @description One line about what the script does
 *   // @key cmd+shift+u
 *   // @schedule weekdays at 09:00
 *
 *   const team = await input.ask("Which team?");
 *   const res = await get("https://api.example.com/users", { query: { team } });
 *   output.log(`Got ${res.data.length} users`);
 *   output.json(res.data).name(`Users in ${team}`);
 *
 * `// @watch ~/Downloads/*.pdf` (optional) runs the script whenever a file
 * arrives in that folder; `input.file()` is that file. The part after the
 * folder is a file name pattern and may be left out to mean every file. As
 * with a schedule, nobody is there to answer questions.
 *
 * `// @schedule` (optional) makes the script run by itself. It takes
 * "every 15 minutes", "every 2 hours", "hourly", "every day at 09:00",
 * "daily at 9am, 5:30pm", "weekdays at 09:00", "mon, thu at 18:30", or a cron
 * expression like "0 9 * * 1-5". Nobody is there when a scheduled run
 * happens: every question is answered with its default, and a question or
 * `input.file()` without one fails the run. So give every input a default in
 * a script meant to be scheduled, and add `// @schedule` only when asked to.
 * A scheduled script gets its keys and tokens from `secrets.get()`, and uses
 * `memory` to act only on what is new since its last run.
 *
 * Rules:
 * - No wrapper function, no `export`, no `import`, no `require`, no npm
 *   packages, no `fetch`, no timers. Only the globals declared in this file
 *   exist, plus standard JavaScript built-ins.
 * - Top-level `await` works. Everything that touches the outside world returns
 *   a Promise: always `await` it.
 * - `output.json(value).name("…")` publishes a named value; the last one is
 *   the script's result. It must be JSON-serializable.
 * - Show results the way they read best: `output.table()` for rows,
 *   `output.chart()` for numbers worth seeing, `output.image()` for pictures,
 *   `output.text()` for a summary in words. Everything published appears in
 *   the app as soon as it is called.
 * - `return` at the top level ends the script early. Throw an Error to fail the run.
 */

// ------------------------------------------------------------------ input

/** A file the user dropped onto the script or picked when asked. */
interface InputFile {
  readonly name: string;
  /** Absolute path on disk. */
  readonly path: string;
  /** Lowercase extension without the dot, e.g. "csv". */
  readonly ext: string;
  /** Size in bytes. */
  readonly size: number;
  text(): Promise<string>;
  json(): Promise<any>;
  /** Rows as objects keyed by the header row. All values are strings. */
  csv(options?: CsvParseOptions): Promise<Record<string, string>[]>;
}

interface AskOptions {
  /**
   * Default "text", or "choice" when `options` is given. "secret" hides what
   * is typed, for a password needed just this once; for a key or token to
   * keep, use `secrets.get()` instead.
   */
  type?: "text" | "number" | "secret" | "confirm" | "choice";
  /** Choices for type "choice". */
  options?: string[];
  placeholder?: string;
  /**
   * Prefilled answer. Also the answer used when the script runs unattended
   * (on a schedule); without a default an unattended question fails the run.
   */
  default?: string | number | boolean;
}

/** One field of `input.form()`. A plain string is shorthand for `{ label }`. */
interface FormField {
  /** Shown next to the control. Defaults to the key, made readable: `dryRun` becomes "Dry run". */
  label?: string;
  /**
   * Default: "select" when `options` is given, "toggle" for a boolean default,
   * "number" for a number default, otherwise "text".
   */
  type?: "text" | "textarea" | "number" | "secret" | "toggle" | "select" | "date" | "datetime" | "time" | "file";
  /**
   * Starting value. Also the value used when the script runs unattended.
   * Dates are strings ("2026-03-05", "2026-03-05T10:30", "14:30") or Date
   * objects; a date field without a default starts at now.
   */
  default?: string | number | boolean | Date;
  /** For "select": plain values, or `{ label, value }` to show one thing and return another. */
  options?: Array<string | number | { label?: string; value: any }>;
  /** Default false. A required field must be filled in before the form can be submitted. */
  required?: boolean;
  placeholder?: string;
  /** A short explanation shown under the label. */
  help?: string;
  /** Bounds for "number". */
  min?: number;
  max?: number;
  /** Allowed extensions for "file". */
  ext?: string | string[];
}

/** Something a script published, as another script reads it back. */
interface EarlierOutput {
  /** The name given with `.name()`; empty if it had none. */
  readonly name: string;
  readonly kind: "json" | "table" | "chart" | "image" | "text";
  /**
   * For "json" the value itself; for "text" the text; for "table"
   * `{ columns: string[], rows: string[][] }`; for "chart" and "image" the
   * description they were drawn from.
   */
  readonly value: any;
}

/** The last run of a script that finished without an error. */
interface EarlierRun {
  /** The script's id. */
  readonly script: string;
  /** ISO 8601, accepted by `new Date()`. */
  readonly startedAt: string;
  readonly finishedAt: string;
  /** What it gave `output.json()` last: the same value `run()` would return. */
  readonly result: any;
  readonly outputs: readonly EarlierOutput[];
  /** The files it saved that still exist. */
  readonly files: readonly InputFile[];
  /** One published value, by the name it was given with `.name()`; undefined if there is none. */
  output(name: string): any;
  /** One saved file, by the name it was given with `.name()` or its file name; undefined if there is none. */
  file(name: string): InputFile | undefined;
}

/**
 * What `input.from()` gives back. Await it for the whole run (null if the
 * script has produced nothing), or go straight for one thing; these fail
 * with a message saying what is missing.
 */
interface EarlierRunLookup extends Promise<EarlierRun | null> {
  /** A file the script saved, by the name given with `.name()` or its file name; without a name, the first one. */
  file(name?: string): Promise<InputFile>;
  /** A value the script published, by the name given with `.name()`. */
  output(name: string): Promise<any>;
  /** What the script gave `output.json()` last: the same value `run()` would return. */
  result(): Promise<any>;
}

declare const input: {
  /**
   * The next file the user dropped onto the script. Each call hands out a
   * different file. When no dropped file is left (or none has the wanted
   * extension) the user is asked to pick one, with `message` as the prompt.
   *
   *   const orders = await input.file("Orders export", { ext: "csv" });
   */
  file(message?: string, options?: { ext?: string | string[] }): Promise<InputFile>;

  /** Every file the user dropped, in order. Empty when nothing was dropped. */
  readonly files: readonly InputFile[];

  /**
   * Pause and ask the user for a value. Resolves to a string ("text",
   * "secret", "choice"), a number or a boolean ("confirm").
   * Rejects if the user cancels.
   */
  ask(message: string, options?: AskOptions): Promise<any>;

  /**
   * Ask for several values at once with one native form. Use this instead of
   * several `input.ask()` calls in a row. Resolves to an object with the same
   * keys as `fields`:
   *
   *   const { from, format, dryRun } = await input.form(
   *     {
   *       from: { label: "Start date", type: "date" },
   *       format: { options: ["csv", "json"], default: "csv" },
   *       dryRun: { default: true },
   *     },
   *     { title: "Export", submit: "Export" }
   *   );
   *
   * Values by type: "text", "textarea", "secret" give a string; "number" a
   * number; "toggle" a boolean; "select" the chosen option's value; "date"
   * "YYYY-MM-DD"; "time" "HH:MM"; "datetime" an ISO 8601 string that
   * `new Date()` accepts; "file" an InputFile. An optional field left empty
   * gives null (an empty string for text). Rejects if the user cancels.
   */
  form(
    fields: Record<string, FormField | string>,
    options?: { title?: string; description?: string; submit?: string }
  ): Promise<Record<string, any>>;

  /**
   * What another script produced the last time it ran successfully, without
   * running it again: one script's output is another's input. Use it to
   * build on work that is already done, such as a report over figures a
   * scheduled script fetched this morning. `run()` is for when the other
   * script has to run now.
   *
   *   const figures = await input.from("Monthly sales").file("The figures");
   *   const totals = await input.from("Monthly sales").output("Totals");
   *
   * Those fail, saying what is missing, if the script has not run yet. To
   * decide for yourself, await the whole thing; it is null when the script
   * has never finished a run successfully:
   *
   *   const sales = await input.from("Monthly sales");
   *   if (sales) output.log(`Using figures from ${sales.finishedAt}`);
   *
   * With `maxAge` (milliseconds) a run older than that does not count,
   * which makes "use it if fresh, otherwise run it" one line:
   *
   *   const rates = (await input.from("Rates", { maxAge: 3600_000 }))?.result ?? await run("Rates");
   *
   * Secrets in what the other script produced are blanked, as everywhere a
   * run is kept.
   */
  from(script: string, options?: { maxAge?: number }): EarlierRunLookup;

  /** Shorthand for `input.ask(message, { type: "confirm" })`. */
  confirm(message: string, options?: { default?: boolean }): Promise<boolean>;

  /**
   * What the calling script passed as the second argument of `run(name, data)`.
   * Null when the user started this script directly.
   */
  readonly data: any;
};

// ----------------------------------------------------------------- output

declare const output: {
  /** Write a line to the run's log. Objects are printed as JSON. */
  log(...values: any[]): void;
  warn(...values: any[]): void;
  error(...values: any[]): void;

  /**
   * Save a file as an output of the run. Awaiting it gives the file's
   * absolute path. Objects are written as pretty JSON. A plain name like
   * "report.csv" goes into the run's output folder; chained scripts share
   * that folder. Add `.name()` when the file name alone does not say what
   * the file is:
   *
   *   await output.file("export.csv", rows).name("Orders in March");
   */
  file(name: string, data: string | object): SavedFile;

  /**
   * Publish a value. The user sees it as a named item in the output, so always
   * give it a name that says what it is:
   *
   *   output.json(users).name("Active users");
   *
   * A script may publish several values. The last one is also the script's
   * result: what `run()` returns to a calling script. In a script that was
   * called with `run()`, the value is only handed back to the caller and not
   * shown to the user.
   */
  json(value: any): PublishedValue;

  /**
   * Show rows as a table. The best way to show a list of records to a person.
   * Rows are objects (keys become columns) or arrays of cells.
   *
   *   output.table(orders, { columns: ["id", "customer", "total"] }).name("Open orders");
   */
  table(rows: object[] | any[][], options?: { columns?: string[] }): PublishedValue;

  /**
   * Draw a chart. Use it for trends ("line", "area"), comparisons ("bar"),
   * shares of a whole ("pie") and relationships ("point").
   *
   * `data` is usually an array of objects. One key is the x axis and one or
   * more numeric keys are plotted; both are found automatically (the first
   * non-numeric key is x, every numeric key is a series) unless you name them.
   * Numbers written as text, as in CSV rows, are fine. Dates on the x axis are
   * "YYYY-MM-DD" or ISO strings. `data` may also be a list of numbers or of
   * [x, y] pairs.
   *
   *   output.chart(sales, { type: "line", x: "month", y: ["online", "stores"] }).name("Sales by channel");
   *   output.chart(rows, { x: "month", y: "total", series: "region" });   // one colour per region
   */
  chart(data: object[] | number[] | [any, number][], options?: ChartOptions): PublishedValue;

  /**
   * Show a picture: a web address, a file path, a file from `input.file()`,
   * a `data:` URL, or SVG markup. SVG is how a script draws something of its
   * own; there is no canvas.
   *
   *   output.image("https://example.com/logo.png").name("Logo");
   *   output.image(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">…</svg>`).name("Diagram");
   */
  image(source: string | InputFile): PublishedValue;

  /**
   * Show a short note in words, such as a summary of what was found.
   * Markdown emphasis works: **bold**, *italic*, `code`, [links](https://…).
   */
  text(markdown: string): PublishedValue;
};

interface ChartOptions {
  /** Default "bar". */
  type?: "bar" | "line" | "area" | "point" | "pie";
  /** The key for the x axis. */
  x?: string;
  /** The key, or keys, to plot. Several keys make several series. */
  y?: string | string[];
  /** A key whose values split one y column into several series. */
  series?: string;
  /** A heading drawn above the chart. */
  title?: string;
}

/** The promise of a saved file's absolute path. */
interface SavedFile extends Promise<string> {
  /** What the user sees this file called. Without it the file name is shown. */
  name(label: string): SavedFile;
}

/** Something published with `output`. It is already showing; `.name()` labels it. */
interface PublishedValue {
  /** What the user sees it called. Without it, it is just "Result", "Chart", "Table"… */
  name(label: string): PublishedValue;
}

/** Same as output.log / output.warn / output.error. */
declare const console: {
  log(...values: any[]): void;
  info(...values: any[]): void;
  debug(...values: any[]): void;
  warn(...values: any[]): void;
  error(...values: any[]): void;
};

// ---------------------------------------------------------------- secrets

/**
 * Passwords, API keys and tokens. They are kept in the Mac's Keychain, never
 * in the script, and are blanked in everything a run shows or keeps: the
 * log, recorded calls, errors, published values and notifications.
 *
 *   const token = await secrets.get("GITHUB_TOKEN", "A GitHub personal access token");
 *   const res = await get(url, { headers: { Authorization: `Bearer ${token}` } });
 *
 * The first time, the user is asked for the value and it is saved. After
 * that it is simply returned, on scheduled runs too. The same name gives the
 * same secret in every script, so name it for what it is, in capitals:
 * "GITHUB_TOKEN", "OPENWEATHER_API_KEY". `description` is what the user reads
 * when asked: say what it is and, if it helps, where to get it.
 */
declare const secrets: {
  get(name: string, description?: string): Promise<string>;
};

// --------------------------------------------------------------------- ai

/**
 * What an answer should look like, written as an example of its shape:
 * "string", "number", "integer" or "boolean" for a value, `[shape]` for a
 * list, `{ key: shape }` for an object, `ai.oneOf(...)` for a fixed choice.
 */
type AIShape = "string" | "number" | "integer" | "boolean" | AIChoice | [AIShape] | { [key: string]: AIShape };
interface AIChoice { readonly __oneOf: string[] }

interface AIOptions {
  /** Standing instructions: a role, a tone, rules for the answer. */
  system?: string;
  /**
   * The shape of the answer. With it, the answer comes back as data in
   * exactly that shape instead of as text:
   *
   *   const { sentiment, topics } = await ai.ask(`Review: ${text}`, {
   *     returns: { sentiment: ai.oneOf("positive", "neutral", "negative"), topics: ["string"] },
   *   });
   */
  returns?: AIShape;
  /** A full JSON Schema instead of `returns`, when the shorthand is not enough. */
  schema?: object;
  /**
   * A provider the person set up in Settings, by name ("OpenAI", "Google").
   * Leave it out to use the one they chose for scripts.
   */
  provider?: string;
  /** A model of that provider. Leave it out to use the one chosen in Settings. */
  model?: string;
  /**
   * Files for the model to look at: pictures (PNG, JPEG, GIF, WebP), PDFs
   * and text files, from `input.file()`, `input.files`, `download()` or a
   * path. Up to 20 MB each.
   *
   *   const invoice = await input.file();
   *   const { total, due } = await ai.ask("Read this invoice.", {
   *     files: [invoice],
   *     returns: { total: "number", due: "string" },
   *   });
   */
  files?: (InputFile | string)[] | InputFile | string;
  /** How hard the model should think. Leave it out for the model's default. */
  effort?: "low" | "medium" | "high";
  /** The longest answer allowed, in tokens. */
  maxTokens?: number;
}

/**
 * Ask an AI model: to summarise, classify, translate, draft, or pull facts
 * out of messy text. It uses the provider and model the person chose in
 * Settings, with their API key, so each call costs them money and takes a
 * few seconds. Ask about many items in one call rather than once per item.
 *
 *   const summary = await ai.ask(`Summarise in two sentences:\n\n${text}`);
 *
 *   const rows = await ai.ask(`Extract every invoice:\n\n${text}`, {
 *     returns: [{ number: "string", total: "number", paid: "boolean" }],
 *   });
 *
 * The model sees only what is in the prompt: put the text or data in it.
 * It works on a schedule too. It fails if no provider is set up, and a
 * run may ask only so many times (25 unless the person raised it).
 */
declare const ai: {
  ask(prompt: string, options?: AIOptions & { returns?: undefined; schema?: undefined }): Promise<string>;
  ask(prompt: string, options: AIOptions): Promise<any>;
  /**
   * Make a picture from a description. It is saved with the run's files
   * and shown as one of its outputs; await it for the file. Needs a provider
   * that makes pictures (OpenAI does; Anthropic does not), and takes ten
   * seconds or more.
   *
   *   const cover = await ai.image("A watercolour of a lighthouse at dawn").name("Cover");
   *   output.image(cover.path);
   */
  image(
    prompt: string,
    options?: {
      /** "1024x1024" (default), "1536x1024" for landscape, "1024x1536" for portrait. */
      size?: string;
      /** Nothing behind the subject, where the model can do that. */
      transparent?: boolean;
      /** The file's name, without extension. */
      name?: string;
      provider?: string;
      model?: string;
    }
  ): Download;
  /** In `returns`: one of a fixed set of answers. */
  oneOf(...choices: string[]): AIChoice;
};

// ----------------------------------------------------------------- memory

/**
 * What this script remembers from one run to the next: the last item it saw,
 * a running total, what it already reported. Values are anything JSON can
 * hold. Each script has its own memory.
 *
 *   const seen = await memory.get("seenIds", []);
 *   const fresh = items.filter((item) => !seen.includes(item.id));
 *   await memory.set("seenIds", [...seen, ...fresh.map((item) => item.id)]);
 */
declare const memory: {
  /** The remembered value, or `fallback` (null when not given) if there is none. */
  get(key: string, fallback?: any): Promise<any>;
  set(key: string, value: any): Promise<void>;
  delete(key: string): Promise<void>;
  /** Every key this script has remembered something under. */
  keys(): Promise<string[]>;
};

// ------------------------------------------------------------------- http

interface RequestOptions {
  headers?: Record<string, string>;
  /** Appended to the URL as a query string. */
  query?: Record<string, string | number | boolean | Array<string | number>>;
  /** Milliseconds. */
  timeout?: number;
  /** Default true: a non-2xx status throws an Error with `.status` and `.response`. */
  throwOnError?: boolean;
}

interface Response {
  status: number;
  /** True for 2xx. */
  ok: boolean;
  url: string;
  /** Header names are lowercase. */
  headers: Record<string, string>;
  /** Raw body. */
  text: string;
  /** Parsed JSON when the body is JSON, otherwise the same string as `text`. */
  data: any;
}

/** A plain object or array body is sent as JSON; a string body is sent as is. */
/** Text is sent as it is, an object as JSON, and a file as its bytes. */
type Body = string | object | InputFile | null;

declare function get(url: string, options?: RequestOptions): Promise<Response>;
declare function post(url: string, body?: Body, options?: RequestOptions): Promise<Response>;
declare function put(url: string, body?: Body, options?: RequestOptions): Promise<Response>;
declare function patch(url: string, body?: Body, options?: RequestOptions): Promise<Response>;
/** HTTP DELETE. Named `del` because `delete` is a reserved word; `http.delete` also works. */
declare function del(url: string, options?: RequestOptions): Promise<Response>;

/** A file `download()` is fetching. Await it for the file; `.name()` labels it. */
interface Download extends Promise<InputFile> {
  /** What the user sees this file called. Without it the file name is shown. */
  name(label: string): Download;
}

/**
 * Fetch something and keep it as a file: a picture, a PDF, a zip, anything
 * that is not text. It is saved with the run's other files and shown as one
 * of its outputs. `get()` is for text and JSON; this is for everything else.
 *
 *   const logo = await download("https://example.com/logo.png").name("Logo");
 *   output.image(logo.path);
 *
 * `name` in the options sets the file name; otherwise the server's is used.
 */
declare function download(url: string, options?: RequestOptions & { name?: string }): Download;

/**
 * Send a form with files in it, the way a web page's upload button does.
 * Each field is text, a file, or a list of files. To send one file as the
 * whole body instead, pass it to `post()` or `put()`.
 *
 *   const picture = await input.file();
 *   await upload("https://api.example.com/photos", { title: "Receipt", photo: picture });
 */
declare function upload(
  url: string,
  fields: Record<string, string | number | boolean | InputFile | InputFile[]>,
  options?: RequestOptions & { method?: string }
): Promise<Response>;

declare const http: {
  get: typeof get;
  post: typeof post;
  put: typeof put;
  patch: typeof patch;
  delete: typeof del;
  request(method: string, url: string, options?: RequestOptions & { body?: Body }): Promise<Response>;
};

// ------------------------------------------------------------- filesystem

/**
 * Read a text file anywhere on disk. Absolute paths and `~/` work; a relative
 * path points into the run's output folder. For files the user gave the
 * script, use `input.file()` instead.
 */
declare function read(path: string): Promise<string>;

/**
 * Write a file anywhere on disk and return its absolute path. For results of
 * the run, use `output.file()` instead.
 */
declare function write(path: string, data: string | object): Promise<string>;

declare const file: {
  read: typeof read;
  write: typeof write;
  exists(path: string): Promise<boolean>;
  /** File names inside a directory. */
  list(path: string): Promise<string[]>;
};

// -------------------------------------------------------------------- csv

interface CsvParseOptions {
  /** Detected from the first line when omitted. */
  delimiter?: string;
  /** Default true: first row is the header and rows become objects. False returns string[][]. */
  header?: boolean;
}

declare const csv: {
  parse(text: string, options?: CsvParseOptions): Record<string, string>[];
  stringify(rows: object[] | any[][], options?: { delimiter?: string; columns?: string[] }): string;
};

// ---------------------------------------------------------------- control

/** What a command run with `shell()` left behind. */
interface ShellResult {
  /** Everything it printed. */
  readonly stdout: string;
  /** Everything it printed as errors or progress. */
  readonly stderr: string;
  /** `stdout` without the line break at its end. */
  readonly text: string;
  /** `stdout` as lines, empty ones left out. */
  readonly lines: string[];
  /** The exit code: 0 means it worked. */
  readonly code: number;
  readonly ok: boolean;
}

/**
 * Run a command in the shell (zsh), as you would type it in Terminal, and
 * get what it printed. It runs in the home folder unless `cwd` says
 * otherwise, with the PATH a Terminal window has. A command that fails
 * throws, with what it printed, unless `throwOnError` is false.
 *
 *   const branch = (await shell("git branch --show-current", { cwd: "~/code/site" })).text;
 *   const files = (await shell("ls ~/Downloads/*.pdf", { throwOnError: false })).lines;
 *   await shell("pbcopy", { input: report });
 *
 * This is the same as typing the command yourself: it can change or
 * delete anything you can. Never build a command out of text that comes
 * from a file, a web page or an AI's answer without checking it first.
 * Mac only.
 */
declare function shell(
  command: string,
  options?: {
    /** The folder to run it in. Default: the home folder. */
    cwd?: string;
    /** Text for the command to read as its input. */
    input?: string;
    /** Stop it after this many milliseconds. Default: no limit. */
    timeout?: number;
    /** Extra environment variables. */
    env?: Record<string, string>;
    /** False to get the result back instead of an error when it fails. */
    throwOnError?: boolean;
  }
): Promise<ShellResult>;

/**
 * Run another script and get its result (what it passed to `output.json`).
 * `name` is the script's `@name`, or its file name without ".js"; for a
 * script in a folder, "folder/file-name" always works, and the file name
 * alone works while no other script shares it. `data` shows
 * up in that script as `input.data`; it also sees the same dropped files.
 * If the other script fails, this call throws.
 */
declare function run(name: string, data?: any): Promise<any>;

/**
 * Run scripts one after another, each handed the result of the one before
 * as its `input.data`. The first gets what this script was handed, and the
 * last one's result is returned, so a pipeline is a script of one line:
 *
 *   return await pipeline("Fetch orders", "Clean orders", "Build report");
 *
 * A function in the list is a step too, for a little glue in between:
 *
 *   return await pipeline("Fetch orders", (orders) => orders.filter((o) => o.paid), "Build report");
 *
 * What the steps publish (tables, charts, files) is shown as if you had run
 * them yourself, and the log says which step is running. If a step fails,
 * the pipeline stops and the error says which one. Steps are named as for
 * `run()`. To hand a file to the next step, put its path in the result.
 */
declare function pipeline(...steps: (string | ((data: any) => any))[]): Promise<any>;

declare function sleep(ms: number): Promise<void>;

/**
 * Shows a notification on the person's computer, so they hear about
 * something without watching the run: a job that took a while is done, a
 * price dropped, a scheduled check found something. Clicking it opens this
 * run. `message` is an optional second line.
 *
 *   notify("Backup finished", `${files.length} files copied`);
 *
 * Use it for what is worth interrupting someone for, once or twice per run;
 * progress belongs in `output.log()`. At most 10 are shown per run.
 */
declare function notify(title: string, message?: string): void;
