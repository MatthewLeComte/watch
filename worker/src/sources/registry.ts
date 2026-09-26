/** Source registry - import all sources here to auto-register. */

import { registerSource } from "./index";
import { source67movies } from "./67movies";

registerSource(source67movies);
// Future sources: registerSource(sourceXYZ);