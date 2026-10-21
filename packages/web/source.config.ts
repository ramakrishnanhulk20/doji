import { defineConfig, defineDocs } from "fumadocs-mdx/config";
import { remarkMdxMermaid } from "fumadocs-core/mdx-plugins/remark-mdx-mermaid";
import { dojiCodeTheme } from "./src/components/docs/shiki-theme";

export const docs = defineDocs({
  dir: "content/docs",
});

export default defineConfig({
  mdxOptions: {
    // A ```mermaid fence becomes <Mermaid chart="..." />, which the page maps to the client component.
    remarkPlugins: [remarkMdxMermaid],
    rehypeCodeOptions: {
      themes: { light: dojiCodeTheme, dark: dojiCodeTheme },
    },
  },
});
