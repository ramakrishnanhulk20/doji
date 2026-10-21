import { createFromSource } from "fumadocs-core/search/server";
import { source } from "../../../../lib/docs-source";

// Each search reads its own query, so this route is answered per request, not cached at build time.
export const { GET } = createFromSource(source);
