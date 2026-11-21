// @name News digest
// @description A pipeline: fetches the Hacker News front page, then has AI summarise it

// Each step gets the result of the one before as its
// input.data. What the steps publish is shown here as if
// you had run them yourself.
return await pipeline(
  "Hacker News top stories",
  "Summarise stories",
);
