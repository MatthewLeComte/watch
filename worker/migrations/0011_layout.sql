-- Where a stored file's first data block starts when it has to be relabelled to open quickly (-1: nothing
-- to do), and which stored file that was worked out for.
ALTER TABLE movie ADD COLUMN mdat_off INTEGER;
ALTER TABLE movie ADD COLUMN layout_etag TEXT;
