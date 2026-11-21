// @name Currency rates
// @description A month of exchange rates against a base currency, as a chart (Frankfurter, ECB data)

const { base, to } = await input.form(
  {
    base: { label: "From", options: ["EUR", "USD", "GBP", "CHF", "JPY"], default: "EUR" },
    to: { label: "To", options: ["USD", "EUR", "GBP", "CHF", "JPY", "SEK", "PLN"], default: "USD" },
  },
  { title: "Currency rates", submit: "Show Rates" }
);
if (base === to) throw new Error("Choose two different currencies.");

const start = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
const series = await get(`https://api.frankfurter.dev/v1/${start}..`, { query: { base, symbols: to } });
const days = Object.entries(series.data.rates).map(([date, rates]) => ({ date, rate: rates[to] }));
if (days.length === 0) throw new Error("No rates came back for that pair.");

const first = days[0].rate;
const last = days[days.length - 1].rate;
const change = ((last - first) / first) * 100;

output.chart(days, { type: "line", x: "date", y: "rate", title: `1 ${base} in ${to}` }).name(`${base} to ${to}`);
output.text(`1 ${base} = **${last} ${to}**, ${change >= 0 ? "up" : "down"} **${Math.abs(change).toFixed(2)}%** over ${days.length} trading days.`).name("Summary");
output.json({ base, to, rate: last, changePercent: Math.round(change * 100) / 100, from: days[0].date, days }).name("Rates");
