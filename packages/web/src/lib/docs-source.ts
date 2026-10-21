import { loader } from "fumadocs-core/source";
import { docs } from "collections/server";

// The page tree, slugs and URLs for everything under content/docs, served at /docs.
export const source = loader({
  baseUrl: "/docs",
  source: docs.toFumadocsSource(),
});
