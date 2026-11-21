// Rhino runtime prelude.
// Evaluated once per run context. Receives the native `host` object and returns
// the entry point `start(name, files, done)`.
//
// Every script gets its own copy of the API bound to its run id, so logs, HTTP
// spans and prompts are attributed to the right script even when several
// chained scripts are running at the same time.
(function (host) {
  "use strict";

  // ---------------------------------------------------------------- helpers

  function format(value) {
    if (typeof value === "string") return value;
    if (value instanceof Error) return value.name + ": " + value.message;
    if (value === undefined) return "undefined";
    if (typeof value === "function") return "[Function " + (value.name || "anonymous") + "]";
    try {
      const text = JSON.stringify(value, null, 2);
      return text === undefined ? String(value) : text;
    } catch (_) {
      return String(value);
    }
  }

  // Result of a run as a JSON string, or null when the script returned nothing.
  function serialize(value) {
    if (value === undefined) return null;
    try {
      const text = JSON.stringify(value, null, 2);
      return text === undefined ? JSON.stringify(String(value)) : text;
    } catch (_) {
      return JSON.stringify(String(value));
    }
  }

  function describe(error) {
    if (error && typeof error === "object" && "message" in error) {
      return {
        name: String(error.name || "Error"),
        message: String(error.message),
        stack: String(error.stack || ""),
        line: Number(error.line) || 0,
        sourceURL: String(error.sourceURL || ""),
      };
    }
    return { name: "Error", message: format(error), stack: "", line: 0, sourceURL: "" };
  }

  // Errors raised by native work are created after the script's frame is gone.
  // `site` is captured while the script is still on the stack, so the reported
  // line points at the script's own call.
  function failure(site, message, extra) {
    const error = new Error(message);
    error.stack = site.stack;
    if (extra) Object.assign(error, extra);
    return error;
  }

  function call(op, runId, args) {
    const site = new Error();
    return new Promise(function (resolve, reject) {
      host[op](runId, args || {}, function (message, value) {
        if (message == null) resolve(value);
        else reject(failure(site, String(message)));
      });
    });
  }

  // -------------------------------------------------------------------- csv

  function detectDelimiter(text) {
    const end = text.indexOf("\n");
    const line = end === -1 ? text : text.slice(0, end);
    let best = ",";
    let bestCount = 0;
    for (const candidate of [",", ";", "\t", "|"]) {
      const count = line.split(candidate).length - 1;
      if (count > bestCount) {
        best = candidate;
        bestCount = count;
      }
    }
    return best;
  }

  const csv = Object.freeze({
    parse: function (text, options) {
      options = options || {};
      text = String(text);
      if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
      const delimiter = options.delimiter || detectDelimiter(text);
      const rows = [];
      let row = [];
      let field = "";
      let quoted = false;
      let wasQuoted = false;
      const length = text.length;

      function endRow() {
        row.push(field);
        if (row.length > 1 || row[0] !== "" || wasQuoted) rows.push(row);
        row = [];
        field = "";
        wasQuoted = false;
      }

      for (let i = 0; i < length; i++) {
        const c = text[i];
        if (quoted) {
          if (c === '"') {
            if (text[i + 1] === '"') {
              field += '"';
              i++;
            } else {
              quoted = false;
            }
          } else {
            field += c;
          }
        } else if (c === '"' && field === "") {
          quoted = true;
          wasQuoted = true;
        } else if (c === delimiter) {
          row.push(field);
          field = "";
        } else if (c === "\n") {
          endRow();
        } else if (c === "\r") {
          if (text[i + 1] === "\n") i++;
          endRow();
        } else {
          field += c;
        }
      }
      if (field !== "" || row.length > 0) endRow();

      if (options.header === false) return rows;
      const header = rows.shift() || [];
      return rows.map(function (cells) {
        const record = {};
        header.forEach(function (key, index) {
          record[key] = cells[index] === undefined ? "" : cells[index];
        });
        return record;
      });
    },

    stringify: function (rows, options) {
      options = options || {};
      const delimiter = options.delimiter || ",";
      rows = Array.from(rows || []);
      const objects = rows.length > 0 && !Array.isArray(rows[0]);

      function cell(value) {
        if (value === null || value === undefined) return "";
        const text = typeof value === "object" ? JSON.stringify(value) : String(value);
        const needsQuotes =
          text.includes(delimiter) || text.includes('"') || text.includes("\n") || text.includes("\r") || text !== text.trim();
        return needsQuotes ? '"' + text.replace(/"/g, '""') + '"' : text;
      }

      const lines = [];
      if (objects) {
        let columns = options.columns;
        if (!columns) {
          columns = [];
          for (const record of rows) {
            for (const key of Object.keys(record || {})) {
              if (!columns.includes(key)) columns.push(key);
            }
          }
        }
        lines.push(columns.map(cell).join(delimiter));
        for (const record of rows) {
          lines.push(columns.map(function (key) { return cell(record ? record[key] : ""); }).join(delimiter));
        }
      } else {
        for (const cells of rows) lines.push(Array.from(cells).map(cell).join(delimiter));
      }
      return lines.join("\n") + "\n";
    },
  });

  // ------------------------------------------------------------------ files

  function wrapFile(runId, info) {
    const dot = info.name.lastIndexOf(".");
    const file = {
      name: info.name,
      path: info.path,
      size: info.size,
      ext: dot > 0 ? info.name.slice(dot + 1).toLowerCase() : "",
      text: function () { return call("readFile", runId, { path: info.path }); },
      json: async function () { return JSON.parse(await file.text()); },
      csv: async function (options) { return csv.parse(await file.text(), options); },
    };
    return Object.freeze(file);
  }

  // ------------------------------------------------------------------ forms

  const FIELD_TYPES = ["text", "multiline", "number", "secret", "toggle", "select", "date", "datetime", "time", "file"];
  const FIELD_ALIASES = { textarea: "multiline", checkbox: "toggle", boolean: "toggle", choice: "select", password: "secret" };

  function pad(number) {
    return String(number).padStart(2, "0");
  }
  function localDate(date) {
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate());
  }
  function localTime(date) {
    return pad(date.getHours()) + ":" + pad(date.getMinutes());
  }

  // "dryRun" and "dry_run" both read as "Dry run".
  function humanize(key) {
    const words = String(key).replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/[_-]+/g, " ").trim().toLowerCase();
    return words.charAt(0).toUpperCase() + words.slice(1);
  }

  // -------------------------------------------------------------------- api

  let fileTokens = 0;

  function headerValue(headers, name) {
    name = name.toLowerCase();
    for (const key in headers) {
      if (key.toLowerCase() === name) return headers[key];
    }
    return undefined;
  }

  function appendQuery(url, query) {
    const parts = [];
    for (const key in query) {
      const value = query[key];
      if (value === undefined || value === null) continue;
      for (const item of Array.isArray(value) ? value : [value]) {
        parts.push(encodeURIComponent(key) + "=" + encodeURIComponent(String(item)));
      }
    }
    if (parts.length === 0) return url;
    return url + (url.includes("?") ? "&" : "?") + parts.join("&");
  }

  function makeAPI(runId, depth, files, data) {
    // A file from input.file(), input.files or download().
    function isFile(value) {
      return !!value && typeof value === "object" && typeof value.path === "string" && typeof value.name === "string";
    }

    function request(method, url, body, options, parts) {
      options = options || {};
      const site = new Error();
      const headers = {};
      for (const key in options.headers || {}) headers[key] = String(options.headers[key]);

      let payload = null;
      let bodyFile = null;
      if (parts) {
        // A form; the native side builds it.
      } else if (isFile(body)) {
        bodyFile = body.path;
      } else if (body !== undefined && body !== null) {
        if (typeof body === "string") {
          payload = body;
        } else {
          payload = JSON.stringify(body);
          if (headerValue(headers, "content-type") === undefined) headers["Content-Type"] = "application/json";
        }
      }

      url = String(url);
      if (options.query) url = appendQuery(url, options.query);

      return call("http", runId, {
        method: method,
        url: url,
        headers: headers,
        body: payload,
        bodyFile: bodyFile,
        multipart: parts || null,
        timeout: Number(options.timeout) || 0,
      }).then(function (raw) {
        const type = String(headerValue(raw.headers, "content-type") || "");
        let data = raw.text;
        const looksLikeJSON = /json/i.test(type) || /^\s*[\[{]/.test(raw.text);
        if (looksLikeJSON) {
          try { data = JSON.parse(raw.text); } catch (_) { data = raw.text; }
        }
        const response = {
          status: raw.status,
          ok: raw.status >= 200 && raw.status < 300,
          url: raw.url,
          headers: raw.headers,
          text: raw.text,
          data: data,
        };
        if (!response.ok && options.throwOnError !== false) {
          throw failure(site, method + " " + url + " failed with status " + raw.status, {
            status: raw.status,
            response: response,
          });
        }
        return response;
      });
    }

    const get = function (url, options) { return request("GET", url, null, options); };
    const del = function (url, options) { return request("DELETE", url, null, options); };
    const post = function (url, body, options) { return request("POST", url, body, options); };
    const put = function (url, body, options) { return request("PUT", url, body, options); };
    const patch = function (url, body, options) { return request("PATCH", url, body, options); };

    // A form with fields and files, the way a browser sends one.
    const upload = function (url, fields, options) {
      const parts = [];
      Object.keys(fields || {}).forEach(function (name) {
        const values = Array.isArray(fields[name]) ? fields[name] : [fields[name]];
        values.forEach(function (value) {
          if (value === undefined || value === null) return;
          if (isFile(value)) parts.push({ name: name, path: value.path, filename: value.name });
          else parts.push({ name: name, value: typeof value === "string" ? value : JSON.stringify(value) });
        });
      });
      if (parts.length === 0) throw new Error("upload() needs something to send, for example upload(url, { file: await input.file() }).");
      return request(String((options && options.method) || "POST").toUpperCase(), url, null, options, parts);
    };

    // Fetches something and keeps it as a file. The promise has `.name()`
    // like output.file(), for what the user sees the file called.
    const download = function (url, options) {
      options = options || {};
      const headers = {};
      for (const key in options.headers || {}) headers[key] = String(options.headers[key]);
      const token = "file-" + (++fileTokens);
      let target = String(url);
      if (options.query) target = appendQuery(target, options.query);
      const saved = call("download", runId, {
        url: target,
        headers: headers,
        name: options.name ? String(options.name) : null,
        timeout: Number(options.timeout) || 0,
        token: token,
      }).then(function (info) { return wrapFile(runId, info); });
      saved.name = function (label) {
        host.nameFile(token, String(label));
        return saved;
      };
      return saved;
    };

    const http = Object.freeze({
      get: get,
      post: post,
      put: put,
      patch: patch,
      delete: del,
      request: function (method, url, options) {
        options = options || {};
        return request(String(method).toUpperCase(), url, options.body, options);
      },
    });

    const read = function (path) { return call("readFile", runId, { path: String(path) }); };
    function writeFile(path, data, token) {
      const text = typeof data === "string" ? data : JSON.stringify(data === undefined ? null : data, null, 2);
      return call("writeFile", runId, { path: String(path), text: text, token: token });
    }
    const write = function (path, data) { return writeFile(path, data, ""); };
    // The promise of the saved path, with `.name()` to say what the user sees
    // the file called. The token is how the name finds the file it belongs to.
    const saveOutput = function (name, data) {
      const token = "file-" + (++fileTokens);
      const saved = writeFile(name, data, token);
      saved.name = function (label) {
        host.nameFile(token, String(label));
        return saved;
      };
      return saved;
    };
    const file = Object.freeze({
      read: read,
      write: write,
      exists: function (path) { return call("fileExists", runId, { path: String(path) }); },
      list: function (path) { return call("listDirectory", runId, { path: String(path) }); },
    });

    function logger(level) {
      return function () {
        host.log(runId, level, Array.prototype.map.call(arguments, format).join(" "));
      };
    }
    const console = Object.freeze({
      log: logger("info"),
      info: logger("info"),
      debug: logger("debug"),
      warn: logger("warn"),
      error: logger("error"),
    });

    function ask(message, options) {
      options = options || {};
      const choices = Array.isArray(options.options) ? options.options.map(String) : [];
      const type = String(options.type || (choices.length > 0 ? "choice" : "text"));
      const fallback = options.default === undefined ? null : options.default;
      return call("ask", runId, {
        message: String(message),
        type: type,
        options: choices,
        placeholder: String(options.placeholder || ""),
        hasDefault: fallback !== null,
        default: fallback,
      }).then(function (answer) {
        return type === "file" && answer ? wrapFile(runId, answer) : answer;
      });
    }

    // Dropped files are handed out one at a time; when none is left (or none
    // matches), the user is asked to pick one.
    const taken = new Set();
    function nextFile(message, options) {
      if (message && typeof message === "object") {
        options = message;
        message = undefined;
      }
      options = options || {};
      const extensions = options.ext
        ? [].concat(options.ext).map(function (ext) { return String(ext).toLowerCase().replace(/^\./, ""); })
        : [];
      for (let i = 0; i < files.length; i++) {
        if (taken.has(i)) continue;
        if (extensions.length > 0 && !extensions.includes(files[i].ext)) continue;
        taken.add(i);
        return Promise.resolve(files[i]);
      }
      const label = message || (extensions.length > 0 ? "Choose a ." + extensions.join(" or .") + " file" : "Choose a file");
      return ask(label, { type: "file", options: extensions });
    }

    // One form with several fields. `fields` maps each result key to a field
    // description; the answer is an object with the same keys.
    function form(fields, options) {
      options = options || {};
      const site = new Error();
      const keys = Object.keys(fields || {});
      if (keys.length === 0) return Promise.reject(failure(site, "input.form() needs at least one field"));

      const specs = [];
      for (const key of keys) {
        let field = fields[key];
        if (typeof field === "string") field = { label: field };
        field = field || {};
        const choices = Array.isArray(field.options) ? field.options : [];

        let type = String(field.type || "").toLowerCase();
        if (!type) {
          type = choices.length > 0 ? "select"
            : typeof field.default === "boolean" ? "toggle"
            : typeof field.default === "number" ? "number"
            : field.default instanceof Date ? "datetime"
            : "text";
        }
        type = FIELD_ALIASES[type] || type;
        if (!FIELD_TYPES.includes(type)) {
          return Promise.reject(failure(site, 'input.form(): field "' + key + '" has unknown type "' + field.type + '". Use one of: ' + FIELD_TYPES.join(", ")));
        }

        // An option is either a plain value or { label, value }.
        const values = choices.map(function (choice) {
          return choice && typeof choice === "object" ? choice.value : choice;
        });
        const labels = choices.map(function (choice) {
          if (choice && typeof choice === "object") return String(choice.label === undefined ? choice.value : choice.label);
          return String(choice);
        });

        let fallback = field.default === undefined ? null : field.default;
        if (type === "select") {
          const index = values.indexOf(fallback);
          fallback = index >= 0 ? index : null;
        } else if (fallback instanceof Date) {
          fallback = type === "date" ? localDate(fallback) : type === "time" ? localTime(fallback) : fallback.toISOString();
        }

        specs.push({
          values: values,
          spec: {
            key: key,
            label: String(field.label === undefined ? humanize(key) : field.label),
            type: type,
            placeholder: String(field.placeholder || ""),
            help: String(field.help || ""),
            required: field.required === true,
            options: type === "file"
              ? [].concat(field.ext || []).map(function (ext) { return String(ext).toLowerCase().replace(/^\./, ""); })
              : labels,
            min: typeof field.min === "number" ? field.min : null,
            max: typeof field.max === "number" ? field.max : null,
            default: fallback,
          },
        });
      }

      return call("form", runId, {
        title: String(options.title || ""),
        description: String(options.description || ""),
        submit: String(options.submit || ""),
        fields: specs.map(function (entry) { return entry.spec; }),
      }).then(function (answers) {
        const result = {};
        for (const entry of specs) {
          let value = answers[entry.spec.key];
          if (value === undefined) value = null;
          if (value !== null && entry.spec.type === "select") value = entry.values[value];
          if (value !== null && entry.spec.type === "file") value = wrapFile(runId, value);
          result[entry.spec.key] = value;
        }
        return result;
      });
    }

    // What another script last produced, read from the history of runs.
    // One script's output is another's input; nothing is run.
    function from(name, options) {
      options = options || {};
      if (name === undefined || name === null || !String(name).trim()) {
        throw new Error("input.from() needs the name of a script, for example input.from(\"Monthly sales\").");
      }
      const site = new Error();
      function parsed(json) {
        try { return JSON.parse(json); } catch (_) { return json; }
      }
      function same(a, b) { return String(a).toLowerCase() === String(b).toLowerCase(); }

      const loaded = call("lastRun", runId, { name: String(name), maxAge: Number(options.maxAge) || 0 }).then(function (run) {
        if (!run) return null;
        const outputs = run.outputs.map(function (item) {
          return Object.freeze({ name: item.name, kind: item.kind, value: parsed(item.json) });
        });
        const produced = run.files.map(function (info) { return wrapFile(runId, info); });
        return Object.freeze({
          script: run.script,
          startedAt: run.startedAt,
          finishedAt: run.finishedAt,
          result: run.resultJSON === null || run.resultJSON === undefined ? null : parsed(run.resultJSON),
          outputs: Object.freeze(outputs),
          files: Object.freeze(produced),
          // By the name the script gave it with .name().
          output: function (label) {
            const found = outputs.find(function (item) { return same(item.name, label); });
            return found ? found.value : undefined;
          },
          // By the name given with .name(), or by file name.
          file: function (label) {
            const index = run.files.findIndex(function (info) { return same(info.label, label) || same(info.name, label); });
            return index === -1 ? undefined : produced[index];
          },
        });
      });

      // Shortcuts for the common case, where the thing has to be there:
      // `await input.from("Sales").file("Figures")`. They fail with what is
      // missing instead of handing back nothing.
      function needed() {
        return loaded.then(function (run) {
          if (!run) {
            throw failure(site, options.maxAge
              ? "“" + name + "” has not produced anything recently enough. Run it first."
              : "“" + name + "” has not produced anything yet. Run it first.");
          }
          return run;
        });
      }
      loaded.file = function (label) {
        return needed().then(function (run) {
          const found = label === undefined ? run.files[0] : run.file(label);
          if (!found) {
            throw failure(site, label === undefined
              ? "The last run of “" + name + "” saved no file."
              : "The last run of “" + name + "” saved no file called “" + label + "”.");
          }
          return found;
        });
      };
      loaded.output = function (label) {
        return needed().then(function (run) {
          const value = run.output(label);
          if (value === undefined) throw failure(site, "The last run of “" + name + "” published nothing called “" + label + "”.");
          return value;
        });
      };
      loaded.result = function () {
        return needed().then(function (run) { return run.result; });
      };
      return loaded;
    }

    const input = Object.freeze({
      files: Object.freeze(files.slice()),
      data: data === undefined ? null : data,
      from: from,
      file: nextFile,
      form: form,
      ask: ask,
      confirm: function (message, options) {
        return ask(message, Object.assign({}, options, { type: "confirm" }));
      },
    });

    // Hands something to the app to show. It appears right away, between
    // the log lines around it; `.name()` then says what it is called.
    function publish(kind, json) {
      const id = host.output(runId, kind, json);
      const published = {
        name: function (label) {
          if (id) host.nameOutput(id, String(label));
          return published;
        },
      };
      return Object.freeze(published);
    }

    function image(source) {
      const site = new Error();
      let shown;
      if (source && typeof source === "object" && typeof source.path === "string") {
        shown = { path: source.path };
      } else if (typeof source === "string" && source.trim() !== "") {
        const text = source.trim();
        if (/^https?:\/\//i.test(text)) shown = { url: text };
        else if (/^data:/i.test(text)) shown = { data: text };
        else if (/^<(\?xml|svg)[\s>]/i.test(text)) shown = { svg: text };
        else shown = { path: text };
      } else {
        throw failure(site, "output.image() takes a web address, a file path, a file from input.file(), a data: URL, or SVG markup.");
      }
      return publish("image", JSON.stringify(shown));
    }

    const CHART_TYPES = ["bar", "line", "area", "point", "pie"];

    function chart(data, options) {
      options = options || {};
      const site = new Error();
      const rows = Array.from(data || []);
      if (rows.length === 0) throw failure(site, "output.chart() needs at least one row of data.");

      let type = String(options.type || "bar").toLowerCase();
      type = { column: "bar", scatter: "point", donut: "pie" }[type] || type;
      if (!CHART_TYPES.includes(type)) {
        throw failure(site, 'output.chart(): unknown type "' + options.type + '". Use one of: ' + CHART_TYPES.join(", "));
      }

      const xValue = function (value) {
        if (typeof value === "number" && isFinite(value)) return value;
        if (value instanceof Date) return value.toISOString();
        return value === null || value === undefined ? "" : String(value);
      };
      // Numbers that arrive as text, as they do from a CSV file, still count.
      const toNumber = function (value) {
        if (typeof value === "number") return value;
        if (typeof value === "string" && value.trim() !== "") return Number(value);
        return NaN;
      };

      const points = [];
      let xLabel = "";
      let yLabel = "";
      if (rows.every(function (row) { return typeof row === "number"; })) {
        // A plain list of numbers: plot them in order.
        rows.forEach(function (y, index) { points.push({ x: index + 1, y: y, series: "" }); });
      } else if (rows.every(Array.isArray)) {
        // [x, y] pairs.
        for (const row of rows) {
          const y = toNumber(row[1]);
          if (isFinite(y)) points.push({ x: xValue(row[0]), y: y, series: "" });
        }
      } else {
        // Objects: one key is x, one or more numeric keys are y.
        const keys = [];
        for (const row of rows) {
          for (const key of Object.keys(row || {})) if (!keys.includes(key)) keys.push(key);
        }
        const isNumeric = function (key) {
          let seen = false;
          for (const row of rows) {
            const value = row ? row[key] : undefined;
            if (value === null || value === undefined || value === "") continue;
            if (!isFinite(toNumber(value))) return false;
            seen = true;
          }
          return seen;
        };
        const seriesKey = options.series === undefined ? null : String(options.series);
        const x = options.x !== undefined
          ? String(options.x)
          : keys.find(function (key) { return key !== seriesKey && !isNumeric(key); }) || keys[0];
        const ys = options.y !== undefined
          ? [].concat(options.y).map(String)
          : keys.filter(function (key) { return key !== x && key !== seriesKey && isNumeric(key); });
        if (ys.length === 0) {
          throw failure(site, 'output.chart() found no numeric column to plot. Name one with { y: "column" }.');
        }
        for (const row of rows) {
          for (const key of ys) {
            const y = toNumber(row ? row[key] : undefined);
            if (!isFinite(y)) continue;
            const series = seriesKey ? String(row[seriesKey]) : ys.length > 1 ? key : "";
            points.push({ x: xValue(row ? row[x] : ""), y: y, series: series });
          }
        }
        xLabel = x;
        yLabel = ys.length === 1 ? ys[0] : "";
      }
      if (points.length === 0) throw failure(site, "output.chart() found no numbers to plot.");

      return publish("chart", JSON.stringify({
        type: type,
        title: String(options.title || ""),
        xLabel: xLabel,
        yLabel: yLabel,
        points: points,
      }));
    }

    function table(rows, options) {
      options = options || {};
      const list = Array.from(rows || []);
      const first = list[0];
      const objects = first !== null && typeof first === "object" && !Array.isArray(first);

      let columns = Array.isArray(options.columns) ? options.columns.map(String) : [];
      if (columns.length === 0) {
        if (objects) {
          for (const row of list) {
            for (const key of Object.keys(row || {})) if (!columns.includes(key)) columns.push(key);
          }
        } else if (Array.isArray(first)) {
          columns = first.map(function (_, index) { return "Column " + (index + 1); });
        } else {
          columns = ["Value"];
        }
      }

      const cell = function (value) {
        if (value === null || value === undefined) return "";
        return typeof value === "object" ? JSON.stringify(value) : String(value);
      };
      // The app shows the first rows; sending a million would only be slow.
      const body = list.slice(0, 1000).map(function (row) {
        if (objects) return columns.map(function (column) { return cell(row ? row[column] : ""); });
        if (Array.isArray(row)) return columns.map(function (_, index) { return cell(row[index]); });
        return [cell(row)];
      });
      const numeric = columns.map(function (_, index) {
        let seen = false;
        for (const row of body) {
          if (row[index] === "") continue;
          if (!isFinite(Number(row[index]))) return false;
          seen = true;
        }
        return seen;
      });
      return publish("table", JSON.stringify({ columns: columns, numeric: numeric, rows: body, total: list.length }));
    }

    let result;
    let hasResult = false;
    const output = Object.freeze({
      log: logger("info"),
      warn: logger("warn"),
      error: logger("error"),
      file: saveOutput,
      json: function (value) {
        result = value;
        hasResult = true;
        return publish("json", serialize(value) || "null");
      },
      image: image,
      chart: chart,
      table: table,
      text: function (value) {
        return publish("text", JSON.stringify(String(value)));
      },
    });

    // Passwords, keys and tokens: saved once, in the user's Keychain.
    const secrets = Object.freeze({
      get: function (name, description) {
        return call("secret", runId, {
          name: String(name === undefined ? "" : name),
          description: description === undefined ? "" : String(description),
        });
      },
    });

    // Questions for an AI model. `returns` is a shorthand for a JSON Schema:
    // { name: "string", tags: ["string"], mood: ai.oneOf("good", "bad") }.
    function schemaFor(shape) {
      if (shape && shape.__oneOf) {
        return { type: "string", enum: shape.__oneOf };
      }
      if (typeof shape === "string") {
        const type = shape.trim().toLowerCase();
        if (["string", "number", "integer", "boolean"].indexOf(type) === -1) {
          throw new Error("ai.ask(): \"" + shape + "\" is not a type. Use \"string\", \"number\", \"integer\" or \"boolean\".");
        }
        return { type: type };
      }
      if (Array.isArray(shape)) {
        if (shape.length !== 1) {
          throw new Error("ai.ask(): a list in `returns` has one item saying what the list holds, for example [\"string\"]. For a fixed set of choices use ai.oneOf(…).");
        }
        return { type: "array", items: schemaFor(shape[0]) };
      }
      if (shape && typeof shape === "object") {
        const keys = Object.keys(shape);
        const properties = {};
        keys.forEach(function (key) { properties[key] = schemaFor(shape[key]); });
        return { type: "object", properties: properties, required: keys, additionalProperties: false };
      }
      throw new Error("ai.ask(): `returns` describes the answer, for example { title: \"string\", tags: [\"string\"] }.");
    }

    // Models sometimes wrap JSON in a code fence even when told not to.
    function unfenced(text) {
      const match = /^\s*```[a-zA-Z]*\s*\n([\s\S]*?)\n?```\s*$/.exec(text);
      return match ? match[1] : text;
    }

    const ai = Object.freeze({
      ask: function (prompt, options) {
        options = options || {};
        const question = prompt === undefined || prompt === null ? "" : typeof prompt === "string" ? prompt : format(prompt);
        if (!question.trim()) throw new Error("ai.ask() needs a question, for example ai.ask(\"Summarise this: \" + text).");
        if (options.effort !== undefined && ["low", "medium", "high"].indexOf(options.effort) === -1) {
          throw new Error("ai.ask(): effort is \"low\", \"medium\" or \"high\".");
        }

        // The top level of structured output has to be an object, so
        // anything else travels inside one and is taken out again.
        let schema = null;
        let wrapped = false;
        if (options.schema !== undefined && options.schema !== null) {
          schema = options.schema;
        } else if (options.returns !== undefined && options.returns !== null) {
          schema = schemaFor(options.returns);
          if (schema.type !== "object") {
            schema = { type: "object", properties: { value: schema }, required: ["value"], additionalProperties: false };
            wrapped = true;
          }
        }

        const args = { prompt: question };
        if (options.files !== undefined && options.files !== null) {
          const files = Array.isArray(options.files) ? options.files : [options.files];
          args.files = files.map(function (file) {
            if (typeof file === "string") return file;
            if (file && typeof file.path === "string") return file.path;
            throw new Error("ai.ask(): `files` holds files from input.file(), input.files or download(), or paths.");
          });
        }
        if (options.system) args.system = String(options.system);
        if (options.provider) args.provider = String(options.provider);
        if (options.model) args.model = String(options.model);
        if (options.effort) args.effort = options.effort;
        if (Number(options.maxTokens) > 0) args.maxTokens = Math.floor(Number(options.maxTokens));
        if (schema) args.schema = JSON.stringify(schema);

        const site = new Error();
        return call("ai", runId, args).then(function (reply) {
          if (!schema) return reply.text;
          let value;
          try {
            value = JSON.parse(unfenced(reply.text));
          } catch (error) {
            throw failure(site, "ai.ask() asked for data, but the answer was not JSON: " + reply.text.slice(0, 200));
          }
          return wrapped && value && typeof value === "object" && "value" in value ? value.value : value;
        });
      },
      // A picture from a description, kept as one of the run's files. The
      // promise has `.name()` like output.file() and download().
      image: function (prompt, options) {
        options = options || {};
        const wanted = prompt === undefined || prompt === null ? "" : String(prompt);
        if (!wanted.trim()) throw new Error("ai.image() needs a description of the picture.");
        const token = "file-" + (++fileTokens);
        const args = { prompt: wanted, token: token, transparent: options.transparent === true };
        if (options.provider) args.provider = String(options.provider);
        if (options.model) args.model = String(options.model);
        if (options.size) args.size = String(options.size);
        if (options.name) args.name = String(options.name);
        const made = call("aiImage", runId, args).then(function (info) { return wrapFile(runId, info); });
        made.name = function (label) {
            host.nameFile(token, String(label));
            return made;
        };
        return made;
      },
      oneOf: function () {
        return { __oneOf: Array.prototype.map.call(arguments, String) };
      },
    });

    // What this script remembers from one run to the next.
    const memory = Object.freeze({
      get: function (key, fallback) {
        return call("memory", runId, { action: "get", key: String(key) }).then(function (json) {
          if (json === null || json === undefined) return fallback === undefined ? null : fallback;
          return JSON.parse(json);
        });
      },
      set: function (key, value) {
        const json = JSON.stringify(value === undefined ? null : value);
        return call("memory", runId, { action: "set", key: String(key), json: json }).then(function () {});
      },
      delete: function (key) {
        return call("memory", runId, { action: "delete", key: String(key) }).then(function () {});
      },
      keys: function () {
        return call("memory", runId, { action: "keys", key: "" });
      },
    });

    return {
      globals: {
        input: input,
        output: output,
        secrets: secrets,
        memory: memory,
        ai: ai,
        get: get,
        post: post,
        put: put,
        patch: patch,
        del: del,
        http: http,
        download: download,
        upload: upload,
        read: read,
        write: write,
        file: file,
        csv: csv,
        console: console,
        sleep: function (ms) { return call("sleep", runId, { ms: Number(ms) || 0 }); },
        notify: function (title, message) {
          const heading = title === undefined || title === null ? "" : (typeof title === "string" ? title : format(title)).trim();
          if (!heading) throw new Error("notify() needs a title, for example notify(\"Backup finished\").");
          const body = message === undefined || message === null ? "" : typeof message === "string" ? message : format(message);
          host.notify(runId, heading, body);
        },
        // A command in the user's shell. A command that fails throws, with
        // what it printed, unless the script asked to look for itself.
        shell: function (command, options) {
          options = options || {};
          const site = new Error();
          const typed = command === undefined || command === null ? "" : String(command);
          return call("shell", runId, {
            command: typed,
            cwd: options.cwd ? String(options.cwd) : null,
            input: options.input === undefined || options.input === null ? null : String(options.input),
            timeout: Number(options.timeout) || 0,
            env: options.env || {},
          }).then(function (raw) {
            const result = Object.freeze({
              stdout: raw.stdout,
              stderr: raw.stderr,
              code: raw.code,
              ok: raw.code === 0 && !raw.timedOut,
              // What was printed, without the line break at the end: what one usually wants.
              text: raw.stdout.replace(/\r?\n$/, ""),
              lines: raw.stdout.split(/\r?\n/).filter(function (line) { return line !== ""; }),
            });
            if (!result.ok && options.throwOnError !== false) {
              const said = (raw.stderr || raw.stdout).trim().split(/\r?\n/).slice(-3).join(" ");
              const why = raw.timedOut ? "took too long and was stopped" : "failed with exit code " + raw.code;
              throw failure(site, "`" + typed + "` " + why + (said ? ": " + said : ""), { result: result });
            }
            return result;
          });
        },
        // `{ show: true }` puts what the other script publishes on show in
        // this run; without it, that stays the other script's own business.
        run: function (name, input, options) {
          return exec(String(name), input, runId, depth + 1, files, !!(options && options.show === true));
        },
      },
      // What the script produced: the value given to output.json(), or failing
      // that whatever its top-level code returned.
      result: function (returned) { return hasResult ? result : returned; },
    };
  }

  // -------------------------------------------------------------- execution

  // `publishes` is `run(name, data, { show: true })`: what the script
  // publishes is shown, as if the user had run it, instead of staying inside
  // the call.
  async function exec(name, data, parentId, depth, files, publishes) {
    if (depth > 32) {
      throw new Error('run("' + name + '") is nested more than 32 levels deep. Is a script calling itself?');
    }
    const runId = host.beginRun(name, parentId, publishes === true);
    try {
      const factory = host.load(name);
      const api = makeAPI(runId, depth, files, data);
      // The user's shared functions, made for this run so that what they
      // log or fetch counts as this script's doing. Each file sees the API
      // and the files before it.
      (host.sharedFactories || []).forEach(function (define) {
        Object.assign(api.globals, define(api.globals));
      });
      const returned = await factory(api.globals);
      const result = api.result(returned);
      host.endRun(runId, null, serialize(result));
      return result;
    } catch (error) {
      host.endRun(runId, describe(error), null);
      throw error;
    }
  }

  return function start(name, files, done, dataJSON) {
    const dropped = (files || []).map(function (info) { return wrapFile("", info); });
    // What whoever started the run handed over; text that is not JSON is passed on as text.
    let data;
    if (typeof dataJSON === "string") {
      try { data = JSON.parse(dataJSON); } catch (_) { data = dataJSON; }
    }
    exec(name, data, null, 0, dropped).then(
      function () { done(); },
      function () { done(); }
    );
  };
})
