-- A saved stream is a rental until kept: expires_at is when it deletes itself. NULL means permanent.
ALTER TABLE movie ADD COLUMN expires_at TEXT;
