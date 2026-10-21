"use client";

import { useEffect } from "react";

// The site-wide smooth scroll takes over the mouse wheel, which stops the sidebar, the search list
// and wide diagrams from scrolling on their own. On the docs pages it steps aside.
export function DocsNativeScroll() {
  useEffect(() => {
    document.body.setAttribute("data-lenis-prevent", "");
    return () => document.body.removeAttribute("data-lenis-prevent");
  }, []);

  return null;
}
