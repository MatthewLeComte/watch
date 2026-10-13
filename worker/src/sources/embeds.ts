/** The stream page for a title is a URL with variables, set as variables on the watch worker (Cloudflare dashboard:
 * Workers > watch > Settings > Variables), so no code names a stream host:
 *
 *   WATCH_EMBED_MOVIE   https://www.rivestream.app/embed?type=movie&id=${id}
 *   WATCH_EMBED_TV      https://www.rivestream.app/embed?type=tv&id=${id}&season=${season}&episode=${episode}
 *
 * The defaults are the two pages worker/RIVESTREAM_EMBED_DOCS.md documents, exactly. Variables: ${id} (the TMDB id),
 * ${season}, ${episode}. A value that is not https or has no ${id} is ignored for the default.
 */

const DEFAULTS = {
  movie: "https://www.rivestream.app/embed?type=movie&id=${id}",
  tv: "https://www.rivestream.app/embed?type=tv&id=${id}&season=${season}&episode=${episode}",
};

export function embedTemplate(env: { WATCH_EMBED_MOVIE?: string; WATCH_EMBED_TV?: string }, kind: "movie" | "tv"): string {
  const set = (kind === "tv" ? env.WATCH_EMBED_TV : env.WATCH_EMBED_MOVIE)?.trim();
  return set && set.startsWith("https://") && set.includes("${id}") ? set : DEFAULTS[kind];
}

/** Replaces the variables that are given and leaves the others, so `${season}` and `${episode}` can be finished by the app. */
export function fill(template: string, values: { id?: number; season?: number; episode?: number }): string {
  return template.replace(/\$\{(id|season|episode)\}/g, (whole, name: "id" | "season" | "episode") =>
    values[name] === undefined ? whole : String(values[name]));
}
