"use client";

import { useEffect, useState } from "react";
import { labStateToSearch, type LabState } from "../../lib/lab-state";
import { setMotionOverride } from "../../lib/motion-mode";
import { Hero } from "../hero/Hero";
import { FoldingScreen } from "../osaka/FoldingScreen";
import { StampMoment } from "../stamp/StampMoment";
import { LabPanel } from "./LabPanel";
import { PaletteSection } from "./PaletteSection";

export function LabShell({ initial }: { initial: LabState }) {
  const [state, setState] = useState(initial);
  const [replayKey, setReplayKey] = useState(0);

  // Smooth scroll lives in the root layout, so the Motion switch reaches it through a shared store.
  useEffect(() => {
    setMotionOverride(state.motion);
    return () => setMotionOverride("full");
  }, [state.motion]);

  const change = (patch: Partial<LabState>) => {
    const next = { ...state, ...patch };
    setState(next);
    window.history.replaceState(window.history.state, "", `${window.location.pathname}${labStateToSearch(next)}`);
  };

  const replay = () => {
    window.scrollTo({ top: 0 });
    setReplayKey((key) => key + 1);
  };

  return (
    <main data-type={state.type}>
      <Hero type={state.type} headline={state.headline} motion={state.motion} replayKey={replayKey} />
      <StampMoment motion={state.motion} />
      <FoldingScreen motion={state.motion} />
      <PaletteSection headline={state.headline} />
      <LabPanel state={state} onChange={change} onReplay={replay} />
    </main>
  );
}
