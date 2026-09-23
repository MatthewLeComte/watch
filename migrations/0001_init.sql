CREATE TABLE movie (
  id TEXT PRIMARY KEY,
  filename TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  ext TEXT NOT NULL,
  title TEXT NOT NULL,
  original_title TEXT,
  year INTEGER,
  overview TEXT NOT NULL DEFAULT '',
  runtime_min INTEGER,
  genres_json TEXT NOT NULL DEFAULT '[]',
  imdb_id TEXT,
  tmdb_id TEXT,
  os_hash TEXT,
  status TEXT NOT NULL,
  match_source TEXT NOT NULL DEFAULT '',
  match_p REAL,
  match_note TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE subtitle (
  movie_id TEXT NOT NULL,
  lang TEXT NOT NULL,
  label TEXT NOT NULL,
  r2_key TEXT NOT NULL,
  hearing_impaired INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL,
  release_name TEXT,
  PRIMARY KEY (movie_id, lang)
);

CREATE TABLE upload (
  movie_id TEXT PRIMARY KEY,
  upload_id TEXT NOT NULL,
  parts_json TEXT NOT NULL DEFAULT '[]'
);

CREATE INDEX movie_created ON movie (created_at DESC);
