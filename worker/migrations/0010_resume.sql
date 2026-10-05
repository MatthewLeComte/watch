-- Where playback stopped (NULL when not started or finished) and when a title was last opened.
ALTER TABLE movie ADD COLUMN resume_s REAL;
ALTER TABLE movie ADD COLUMN last_played_at TEXT;
