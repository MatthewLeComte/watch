export interface Env {
  watch: D1Database;
  /** Bucket name is `watch`. Binding id differs because Workers reject two bindings named watch. */
  watch_bucket: R2Bucket;
  STREAM: StreamBinding;
  WATCH_KEY: string;
  /** Secrets Store binding: Ed25519 public key for the Roku channel. */
  WATCH_PUBLIC_KEY: StoreSecret;
  /** Secrets Store binding: Ed25519 private key for the Roku channel. */
  WATCH_PRIVATE_KEY: StoreSecret;
  /** TMDB API key (v3 auth). */
  WATCH_TMDB_API_KEY?: string;
  /** TMDB read access token (v4 auth, Bearer). */
  WATCH_TMDB_API_READ_ACCESS_TOKEN?: string;
  OPENSUBTITLES_API_KEY?: string;
  /** Comma-separated Piped API base URLs for trailer resolution. Empty = built-in defaults. */
  TRAILER_RESOLVER?: string;
}

/** Structural type for a Secrets Store secret binding (runtime provides .get()). */
export interface StoreSecret {
  get(): Promise<string>;
}
