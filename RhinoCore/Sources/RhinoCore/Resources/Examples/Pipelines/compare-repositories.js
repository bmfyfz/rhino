// @name Compare repositories
// @description Runs "GitHub repository" for two repositories at once and compares them

const first = await input.ask("First repository", { default: "swiftlang/swift" });
const second = await input.ask("Second repository", { default: "rust-lang/rust" });

// run() starts another script and gives back its result;
// the second argument is what it finds in input.data.
const [a, b] = await Promise.all([run("GitHub repository", { repo: first }), run("GitHub repository", { repo: second })]);

output.table([
  { "": "Stars", [a.repo]: a.stars.toLocaleString(), [b.repo]: b.stars.toLocaleString() },
  { "": "Forks", [a.repo]: a.forks.toLocaleString(), [b.repo]: b.forks.toLocaleString() },
  { "": "Open issues", [a.repo]: a.openIssues.toLocaleString(), [b.repo]: b.openIssues.toLocaleString() },
  { "": "Latest release", [a.repo]: a.latestRelease ?? "none", [b.repo]: b.latestRelease ?? "none" },
]).name(`${a.repo} and ${b.repo}`);
output.chart([{ repo: a.repo, stars: a.stars }, { repo: b.repo, stars: b.stars }], { type: "bar", x: "repo", y: "stars", title: "Stars" }).name("Stars");
await output.file("repositories.csv", csv.stringify([a, b])).name("Both, as CSV");
output.json({ [a.repo]: a, [b.repo]: b }).name("Comparison");
