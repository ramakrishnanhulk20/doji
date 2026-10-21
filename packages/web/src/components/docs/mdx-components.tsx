import type { ComponentProps } from "react";
import type { MDXComponents } from "mdx/types";
import defaultMdxComponents from "fumadocs-ui/mdx";
import { Callout } from "fumadocs-ui/components/callout";
import { Mermaid } from "./Mermaid";

// The class lets docs.css restyle the callout without touching the Fumadocs source.
function DocsCallout(props: ComponentProps<typeof Callout>) {
  return <Callout {...props} className="docs-callout" />;
}

export function getMdxComponents(components?: MDXComponents): MDXComponents {
  return {
    ...defaultMdxComponents,
    Callout: DocsCallout,
    Mermaid,
    ...components,
  };
}
