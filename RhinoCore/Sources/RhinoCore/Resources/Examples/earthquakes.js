// @name Earthquakes today
// @description Every earthquake of magnitude 4.5 or more in the last day (USGS)

const feed = await get("https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson");
const quakes = feed.data.features
  .map((feature) => ({
    magnitude: feature.properties.mag,
    place: feature.properties.place,
    time: new Date(feature.properties.time).toISOString().slice(0, 16).replace("T", " "),
    depth: Math.round(feature.geometry.coordinates[2]),
  }))
  .sort((a, b) => b.magnitude - a.magnitude);

output.log(`${quakes.length} earthquakes in the last 24 hours`);
output.table(quakes.map((quake) => ({ Magnitude: quake.magnitude, Where: quake.place, "When (UTC)": quake.time, "Depth km": quake.depth }))).name("Last 24 hours");
output.chart(quakes.slice(0, 12).map((quake) => ({ place: quake.place.replace(/^.* of /, ""), magnitude: quake.magnitude })), {
  type: "bar",
  x: "place",
  y: "magnitude",
  title: "Strongest today",
}).name("Strongest");

// Worth an interruption only when it is a big one, which makes this a good script to schedule.
const strongest = quakes[0];
if (strongest && strongest.magnitude >= 6.5) {
  notify(`Magnitude ${strongest.magnitude} earthquake`, strongest.place);
}
output.json(quakes).name("Earthquakes");
