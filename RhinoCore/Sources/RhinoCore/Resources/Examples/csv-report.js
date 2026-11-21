// @name CSV report
// @description Drop a CSV file: shows it as a table, charts a number column, and saves it as JSON

const file = await input.file("Choose a CSV file", { ext: "csv" });
const rows = await file.csv();
if (rows.length === 0) throw new Error(`${file.name} has no rows.`);
output.log(`${rows.length} rows, ${Object.keys(rows[0]).length} columns in ${file.name}`);
output.table(rows).name(file.name);

// The first column whose values are all numbers is worth a chart, against the first that is not.
const columns = Object.keys(rows[0]);
const isNumeric = (column) => rows.every((row) => row[column] !== "" && !Number.isNaN(Number(row[column])));
const value = columns.find(isNumeric);
const label = columns.find((column) => !isNumeric(column));
if (value && label) {
  const points = rows.slice(0, 30).map((row) => ({ [label]: row[label], [value]: Number(row[value]) }));
  output.chart(points, { type: "bar", x: label, y: value, title: `${value} by ${label}` }).name(`${value} by ${label}`);
}

await output.file(file.name.replace(/\.csv$/i, ".json"), rows).name("As JSON");
output.json({ file: file.name, rows: rows.length, columns }).name("Summary");
