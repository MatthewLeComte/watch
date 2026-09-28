export interface Env {
  watch: D1Database;
  /** Bucket name is `watch`. Binding id differs because Workers reject two bindings named watch. */
  watch_bucket: R2Bucket;
  STREAM: StreamBinding;
  /** Cloudflare Browser Rendering. Launch with puppeteer.launch(env.BROWSER). */
  BROWSER?: import("@cloudflare/puppeteer").BrowserWorker;
  /** KV namespace for RiveStream session persistence (cookies, localStorage). */
  RIVESTREAM_SESSION?: KVNamespace;
  /** Residential proxy for RiveStream (http://user:pass@host:port). Empty = direct. */
  RIVESTREAM_PROXY?: string;
  WATCH_KEY: string;
  /** Secrets Store binding: Ed25519 public key for the Roku channel. */
  WATCH_PUBLIC_KEY: StoreSecret;
  /** Secrets Store binding: Ed25519 private key for the Roku channel. */
  WATCH_PRIVATE_KEY: StoreSecret;
  /** TMDB API key (v3 auth). Account secret store binding, or a plain string in dev. */
  WATCH_TMDB_API_KEY?: string | StoreSecret;
  /** TMDB read access token (v4 auth, Bearer). Account secret store binding, or a plain string in dev. */
  WATCH_TMDB_API_READ_ACCESS_TOKEN?: string | StoreSecret;
  OPENSUBTITLES_API_KEY?: string;
  /** Comma-separated Piped API base URLs for trailer resolution. Empty = built-in defaults. */
  TRAILER_RESOLVER?: string;
}

/** Structural type for a Secrets Store secret binding (runtime provides .get()). */
export interface StoreSecret {
  get(): Promise<string>;
}
