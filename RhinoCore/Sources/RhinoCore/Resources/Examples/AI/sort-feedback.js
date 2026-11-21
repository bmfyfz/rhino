// @name Sort feedback
// @description Asks AI to sort customer comments by mood and topic

const text = await input.ask("Paste the comments, one per line", {
  default: "The app is fast and lovely.\nI was charged twice this month.\nPlease add a dark mode.",
});
const comments = text.split("\n").map((line) => line.trim()).filter(Boolean);
output.log(`Asking the AI about ${comments.length} comments`);

// One question for all of them: faster and cheaper than one each.
const numbered = comments.map((comment, index) => `${index + 1}. ${comment}`).join("\n");
const sorted = await ai.ask(`Sort these customer comments by mood and topic:\n\n${numbered}`, {
  returns: [{ comment: "string", mood: ai.oneOf("happy", "neutral", "unhappy"), topic: "string" }],
});

const unhappy = sorted.filter((row) => row.mood === "unhappy");
output.table(sorted).name("Comments by mood");
output.text(`**${unhappy.length}** of ${sorted.length} comments are unhappy.`).name("Summary");
output.json(sorted).name("Sorted comments");
