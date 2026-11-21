// @name GitHub repository
// @description Stars, issues, languages and the latest release of a public repository

const repo = input.data?.repo ?? (await input.ask("Which repository?", { default: "swiftlang/swift", placeholder: "owner/name" }));

const api = `https://api.github.com/repos/${repo}`;
const headers = { Accept: "application/vnd.github+json" };
output.log(`Fetching ${repo}`);
const [about, languages, release] = await Promise.all([
  get(api, { headers }),
  get(`${api}/languages`, { headers }),
  get(`${api}/releases/latest`, { headers, throwOnError: false }),
]);

const total = Object.values(languages.data).reduce((sum, bytes) => sum + bytes, 0);
const shares = Object.entries(languages.data)
  .map(([language, bytes]) => ({ language, share: Math.round((bytes / total) * 1000) / 10 }))
  .filter((row) => row.share >= 1);
output.chart(shares, { type: "pie", x: "language", y: "share", title: `Languages in ${repo} (%)` }).name("Languages");

const stats = {
  repo: about.data.full_name,
  description: about.data.description,
  stars: about.data.stargazers_count,
  forks: about.data.forks_count,
  openIssues: about.data.open_issues_count,
  language: about.data.language,
  latestRelease: release.ok ? release.data.tag_name : null,
  updated: about.data.pushed_at,
};
output.table([
  { What: "Stars", Value: stats.stars.toLocaleString() },
  { What: "Forks", Value: stats.forks.toLocaleString() },
  { What: "Open issues", Value: stats.openIssues.toLocaleString() },
  { What: "Latest release", Value: stats.latestRelease ?? "none" },
  { What: "Last push", Value: stats.updated.slice(0, 10) },
]).name(repo);
output.json(stats).name("Repository");
