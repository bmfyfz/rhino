// @name Picture of the day
// @description Downloads Wikipedia's picture of the day and shows it with its caption

const today = new Date();
const path = [today.getUTCFullYear(), String(today.getUTCMonth() + 1).padStart(2, "0"), String(today.getUTCDate()).padStart(2, "0")].join("/");
const featured = await get(`https://api.wikimedia.org/feed/v1/wikipedia/en/featured/${path}`);
const picture = featured.data.image;
if (!picture) throw new Error("Wikipedia has no picture of the day today.");

output.log(`Downloading "${picture.title.replace(/^File:/, "")}"`);
// A picture is not text, so it is downloaded to a file instead of fetched with get().
const file = await download(picture.thumbnail.source).name("Picture of the day");
output.image(file.path).name(picture.title.replace(/^File:/, "").replace(/\.\w+$/, ""));
output.text(`${picture.description?.text ?? ""}\n\n*${picture.artist?.text ?? "Unknown author"}, ${picture.license?.type ?? "see Wikipedia for the licence"}*`).name("Caption");
output.json({ title: picture.title, page: picture.file_page, saved: file.path }).name("Details");
