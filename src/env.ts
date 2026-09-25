export interface Env {
  watch: D1Database;
  /** Bucket name is `watch`. Binding id differs because Workers reject two bindings named watch. */
  watch_bucket: R2Bucket;
  STREAM: StreamBinding;
  WATCH_KEY: string;
  /** Public key ID for the Roku channel (identifies which key is used). */
  WATCH_PUBLIC_KEY: string;
  /** Private secret for the Roku channel (authenticates requests). */
  WATCH_PRIVATE_KEY: string;
  /** Comma-separated device UUIDs allowed. Empty = allow any device with valid API key. */
  ROKU_ALLOWED_DEVICES?: string;
  OPENSUBTITLES_API_KEY?: string;
}
