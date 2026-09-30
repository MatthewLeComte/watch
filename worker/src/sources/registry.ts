/** Source registry - documented sources only: TMDB metadata + Rive embed links. */

import { registerSource } from "./index";
import { sourceRiveStream } from "./rivestream";
import { sourceMeta } from "./meta";

registerSource(sourceRiveStream);
registerSource(sourceMeta);
