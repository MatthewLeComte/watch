/** Source registry - import all sources here to auto-register. */

import { registerSource } from "./index";
import { source67movies } from "./67movies";
import { sourceTmdbVixsrc } from "./tmdb_vixsrc";
import { sourceMeta } from "./meta";
import { sourceHeadless } from "./headless";
import { sourceRiveStream } from "./rivestream";

registerSource(source67movies);
registerSource(sourceTmdbVixsrc);
registerSource(sourceMeta);
registerSource(sourceHeadless);
registerSource(sourceRiveStream);
// Future sources: registerSource(sourceXYZ);