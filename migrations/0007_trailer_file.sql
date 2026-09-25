ALTER TABLE movie ADD COLUMN trailer_r2_key TEXT;
ALTER TABLE movie ADD COLUMN trailer_bytes INTEGER;
ALTER TABLE movie ADD COLUMN trailer_quality TEXT;
ALTER TABLE movie ADD COLUMN trailer_status TEXT DEFAULT 'missing';
ALTER TABLE movie ADD COLUMN trailer_note TEXT;
