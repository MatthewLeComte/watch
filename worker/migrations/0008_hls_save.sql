CREATE TABLE hls_job (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  tmdb_id INTEGER NOT NULL,
  media_type TEXT NOT NULL,
  season INTEGER NOT NULL DEFAULT 1,
  episode INTEGER NOT NULL DEFAULT 1,
  year INTEGER,
  imdb_id TEXT,
  poster TEXT,
  variant_url TEXT NOT NULL,
  referer TEXT,
  vheight INTEGER NOT NULL,
  vbandwidth INTEGER NOT NULL,
  durations_json TEXT NOT NULL DEFAULT '[]',
  total INTEGER NOT NULL,
  done INTEGER NOT NULL DEFAULT 0,
  bytes INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'saving',
  movie_id TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX hls_job_status ON hls_job (status);
