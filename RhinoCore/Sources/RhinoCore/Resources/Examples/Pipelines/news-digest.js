// @name News digest
// @description A pipeline: fetches the Hacker News front page, then has AI summarise it

// Each run() hands its result to the next as input.data.
// { show: true } puts what a step publishes on show here,
// as if you had run that step yourself.
const stories = await run("Hacker News top stories", input.data, { show: true });
return await run("Summarise stories", stories, { show: true });
