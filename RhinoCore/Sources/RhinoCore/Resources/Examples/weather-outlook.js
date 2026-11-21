// @name Weather outlook
// @description The week ahead for any city, as a chart and a table (Open-Meteo, no key needed)

const { city, days } = await input.form(
  {
    city: { label: "City", default: "Lisbon", required: true },
    days: { label: "Days ahead", type: "number", default: 7, min: 1, max: 14 },
  },
  { title: "Weather outlook", submit: "Show Forecast" }
);

output.log(`Looking up ${city}`);
const found = await get("https://geocoding-api.open-meteo.com/v1/search", { query: { name: city, count: 1 } });
const place = found.data.results?.[0];
if (!place) throw new Error(`No place called "${city}" was found.`);

const forecast = await get("https://api.open-meteo.com/v1/forecast", {
  query: {
    latitude: place.latitude,
    longitude: place.longitude,
    daily: "temperature_2m_max,temperature_2m_min,precipitation_sum",
    timezone: "auto",
    forecast_days: days,
  },
});
const daily = forecast.data.daily;
const rows = daily.time.map((date, index) => ({
  date,
  high: daily.temperature_2m_max[index],
  low: daily.temperature_2m_min[index],
  rain: daily.precipitation_sum[index],
}));

const where = `${place.name}, ${place.country}`;
output.chart(rows, { type: "line", x: "date", y: ["high", "low"], title: `Temperature in ${where} (°C)` }).name("Temperature");
output.table(rows.map((row) => ({ Date: row.date, "High °C": row.high, "Low °C": row.low, "Rain mm": row.rain }))).name(`Next ${rows.length} days`);

const warmest = rows.reduce((best, row) => (row.high > best.high ? row : best));
const wet = rows.filter((row) => row.rain >= 1).length;
output.text(`**${where}**: warmest on ${warmest.date} at **${warmest.high} °C**, and rain on **${wet}** of ${rows.length} days.`).name("Summary");
output.json({ place: where, days: rows }).name("Forecast");
