"use client";

import { useEffect, useId, useState, type CSSProperties } from "react";

type MermaidApi = (typeof import("mermaid"))["default"];

const FALLBACK_FONT = "ui-sans-serif, system-ui, sans-serif";

// Mermaid is large, so it loads on the first diagram and is set up once for every diagram after.
let mermaidReady: Promise<MermaidApi> | undefined;

function loadMermaid(): Promise<MermaidApi> {
  mermaidReady ??= import("mermaid").then(async ({ default: mermaid }) => {
    // Text is measured at draw time, so wait for the page fonts before the first diagram.
    await document.fonts.ready;
    const plexSans = getComputedStyle(document.body).getPropertyValue("--font-plex-sans").trim();

    mermaid.initialize({
      startOnLoad: false,
      theme: "base",
      securityLevel: "strict",
      suppressErrorRendering: true,
      themeVariables: {
        darkMode: true,
        background: "#0E0C0B",
        primaryColor: "#171412",
        primaryTextColor: "#F1E6D2",
        primaryBorderColor: "#4A423C",
        lineColor: "#B9AE9C",
        secondaryColor: "#221E1B",
        secondaryTextColor: "#F1E6D2",
        secondaryBorderColor: "#4A423C",
        tertiaryColor: "#171412",
        tertiaryTextColor: "#F1E6D2",
        tertiaryBorderColor: "#2E2925",
        textColor: "#F1E6D2",
        mainBkg: "#171412",
        nodeBorder: "#4A423C",
        nodeTextColor: "#F1E6D2",
        clusterBkg: "#0E0C0B",
        clusterBorder: "#2E2925",
        titleColor: "#F1E6D2",
        edgeLabelBackground: "#171412",
        noteBkgColor: "#221E1B",
        noteTextColor: "#F1E6D2",
        noteBorderColor: "#4A423C",
        actorBkg: "#171412",
        actorBorder: "#4A423C",
        actorTextColor: "#F1E6D2",
        actorLineColor: "#4A423C",
        signalColor: "#B9AE9C",
        signalTextColor: "#F1E6D2",
        labelBoxBkgColor: "#221E1B",
        labelBoxBorderColor: "#4A423C",
        labelTextColor: "#F1E6D2",
        loopTextColor: "#F1E6D2",
        activationBkgColor: "#221E1B",
        activationBorderColor: "#4A423C",
        sequenceNumberColor: "#0E0C0B",
        fontFamily: plexSans || FALLBACK_FONT,
        fontSize: "15px",
      },
      // Natural size, so the card scrolls sideways on a phone instead of shrinking the text.
      flowchart: { useMaxWidth: false, htmlLabels: true, curve: "basis" },
      sequence: { useMaxWidth: false },
      state: { useMaxWidth: false },
      er: { useMaxWidth: false },
      class: { useMaxWidth: false },
    });

    return mermaid;
  });

  return mermaidReady;
}

type DrawState = { status: "drawing" } | { status: "done"; svg: string; width: number } | { status: "failed" };

export function Mermaid({ chart }: { chart: string }) {
  const rawId = useId();
  const [state, setState] = useState<DrawState>({ status: "drawing" });

  useEffect(() => {
    let cancelled = false;
    const drawId = `mermaid-${rawId.replace(/[^a-zA-Z0-9]/g, "")}`;

    loadMermaid()
      .then((mermaid) => mermaid.render(drawId, chart))
      .then(({ svg }) => {
        if (cancelled) return;
        const viewBoxWidth = svg.match(/viewBox="[-\d.]+ [-\d.]+ ([\d.]+) [\d.]+"/)?.[1];
        setState({ status: "done", svg, width: viewBoxWidth ? Math.ceil(Number(viewBoxWidth)) : 0 });
      })
      .catch(() => {
        if (!cancelled) setState({ status: "failed" });
      });

    return () => {
      cancelled = true;
    };
  }, [chart, rawId]);

  if (state.status === "failed") {
    return (
      <div className="docs-mermaid docs-mermaid-failed" role="group" aria-label="Diagram source">
        <p>This diagram could not be drawn. Its source is below.</p>
        <pre>{chart}</pre>
      </div>
    );
  }

  if (state.status === "drawing") {
    return <div className="docs-mermaid docs-mermaid-drawing shimmer" role="status" aria-label="Drawing the diagram" />;
  }

  return (
    <div
      className="docs-mermaid"
      role="region"
      aria-label="Diagram"
      tabIndex={0}
      style={state.width > 0 ? ({ "--mermaid-width": `${state.width}px` } as CSSProperties) : undefined}
      dangerouslySetInnerHTML={{ __html: state.svg }}
    />
  );
}
