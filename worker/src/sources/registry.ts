/** Source registry - only working sources. */

import { registerSource } from "./index";
import { sourceRiveStream } from "./rivestream";
import { sourceMeta } from "./meta";

registerSource(sourceRiveStream);
registerSource(sourceMeta);
// Only RiveStream + Meta (RiveStream) are working sources