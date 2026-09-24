CREATE TABLE movie_cache (
  imdb_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  year INTEGER,
  overview TEXT NOT NULL DEFAULT '',
  poster_url TEXT,
  runtime_min INTEGER,
  genres_json TEXT NOT NULL DEFAULT '[]',
  source TEXT NOT NULL,
  fetched_at TEXT NOT NULL
);
