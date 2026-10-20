"use client";

import { useEffect, useState } from "react";
import { MotionConfig, motion } from "motion/react";
import type { LabState } from "../../lib/lab-state";
import "./lab.css";

type Option<T> = { value: T; label: string };

type SegmentedProps<T extends string | number> = {
  name: string;
  options: readonly Option<T>[];
  value: T;
  onChange: (value: T) => void;
};

function Segmented<T extends string | number>({ name, options, value, onChange }: SegmentedProps<T>) {
  return (
    <div className="lab-field">
      <span className="lab-field-label">{name}</span>
      <div className="lab-segments" role="group" aria-label={name}>
        {options.map((option) => {
          const active = option.value === value;
          return (
            <button
              key={option.value}
              type="button"
              className="lab-segment"
              aria-pressed={active}
              onClick={() => onChange(option.value)}
            >
              {active && (
                <motion.span
                  layoutId={`lab-active-${name}`}
                  className="lab-segment-active"
                  transition={{ type: "spring", duration: 0.25, bounce: 0 }}
                />
              )}
              <span className="lab-segment-text">{option.label}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

type LabPanelProps = {
  state: LabState;
  onChange: (patch: Partial<LabState>) => void;
  onReplay: () => void;
};

export function LabPanel({ state, onChange, onReplay }: LabPanelProps) {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [open]);

  return (
    <MotionConfig reducedMotion="user">
      <aside className="lab-panel" data-open={open} aria-label="Lab controls">
        <button type="button" className="lab-toggle" aria-expanded={open} onClick={() => setOpen((value) => !value)}>
          Lab
        </button>
        <div className="lab-body">
          <p className="lab-title">Lab</p>
          <Segmented
            name="Type"
            value={state.type}
            onChange={(type) => onChange({ type })}
            options={[
              { value: "a", label: "A Shippori" },
              { value: "b", label: "B Fraunces" },
            ]}
          />
          <Segmented
            name="Headline"
            value={state.headline}
            onChange={(headline) => onChange({ headline })}
            options={[
              { value: 1, label: "1" },
              { value: 2, label: "2" },
              { value: 3, label: "3" },
            ]}
          />
          <Segmented
            name="Motion"
            value={state.motion}
            onChange={(motionMode) => onChange({ motion: motionMode })}
            options={[
              { value: "full", label: "Full" },
              { value: "reduced", label: "Reduced" },
            ]}
          />
          <button type="button" className="lab-replay" onClick={onReplay}>
            Replay entrance
          </button>
        </div>
      </aside>
    </MotionConfig>
  );
}
