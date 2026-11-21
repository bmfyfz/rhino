// @name Summarise stories
// @description Asks AI what today's Hacker News front page is about

// As a pipeline step this gets the stories as input.data.
// Run by itself, it uses what "Hacker News top stories"
// produced last, without running it again.
const stories = input.data ?? (await input.from("Hacker News top stories").output("Stories"));

output.log(`Asking the AI about ${stories.length} headlines`);
const digest = await ai.ask(
  "These are the headlines on the Hacker News front page right now:\n\n" + stories.map((story) => `- ${story.title} (${story.points} points)`).join("\n"),
  {
    system: "You brief a busy reader. Be specific and plain; no hype.",
    returns: { themes: [{ theme: "string", headlines: ["string"] }], oneLine: "string" },
  }
);

output.text(`**Today:** ${digest.oneLine}\n\n` + digest.themes.map((group) => `**${group.theme}**\n` + group.headlines.map((title) => `- ${title}`).join("\n")).join("\n\n")).name("Briefing");
output.json(digest).name("Themes");
