"use client";

import { useEffect, useRef, useState } from "react";

/** Turns true the first time `threshold` of the element is on screen, and stays true. */
export function useInViewOnce<T extends Element>(threshold: number) {
  const ref = useRef<T>(null);
  const [seen, setSeen] = useState(false);

  useEffect(() => {
    const element = ref.current;
    if (!element || seen) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting) {
          setSeen(true);
          observer.disconnect();
        }
      },
      { threshold },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [seen, threshold]);

  return [ref, seen] as const;
}
