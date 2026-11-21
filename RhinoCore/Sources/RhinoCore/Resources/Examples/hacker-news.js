// @name Hacker News top stories
// @description The front page right now, with what is new since the last run

const count = input.data?.count ?? 15;
const ids = (await get("https://hacker-news.firebaseio.com/v0/topstories.json")).data.slice(0, count);
output.log(`Fetching ${ids.length} stories`);
const items = await Promise.all(ids.map((id) => get(`https://hacker-news.firebaseio.com/v0/item/${id}.json`)));

const stories = items.map((item) => ({
  id: item.data.id,
  title: item.data.title,
  points: item.data.score,
  comments: item.data.descendants ?? 0,
  url: item.data.url ?? `https://news.ycombinator.com/item?id=${item.data.id}`,
}));

// Remembered between runs, so a scheduled run can tell what it has not shown before.
const seen = await memory.get("seen", []);
const fresh = stories.filter((story) => !seen.includes(story.id));
await memory.set("seen", [...new Set([...stories.map((story) => story.id), ...seen])].slice(0, 500));

output.table(stories.map((story) => ({ Title: story.title, Points: story.points, Comments: story.comments }))).name("Front page");
output.text(
  fresh.length === 0
    ? "Nothing new since the last run."
    : `**${fresh.length} new** since the last run:\n\n` + fresh.map((story) => `- ${story.title}`).join("\n")
).name("New stories");
output.json(stories).name("Stories");
