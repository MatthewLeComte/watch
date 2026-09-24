export interface Env {
  watch: D1Database;
  /** Bucket name is `watch`. Binding id differs because Workers reject two bindings named watch. */
  watch_bucket: R2Bucket;
  STREAM: StreamBinding;
  WATCH_KEY: string;
  OPENSUBTITLES_API_KEY?: string;
}
