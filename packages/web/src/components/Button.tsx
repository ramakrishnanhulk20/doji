"use client";

import type { CSSProperties, MouseEvent, ReactNode } from "react";
import { Seal } from "./Seal";
import "./button.css";

type ButtonProps = {
  variant?: "primary" | "secondary";
  /** Adds the arrow that slides right on hover. */
  arrow?: boolean;
  loading?: boolean;
  disabled?: boolean;
  /** Lab only: holds a hover or focus look so it can sit next to the other states. */
  forceState?: "hover" | "focus";
  /** When set the button renders as an anchor. "#" is a dead link that does nothing. */
  href?: string;
  className?: string;
  style?: CSSProperties;
  children: ReactNode;
};

function Arrow() {
  return (
    <svg className="btn-arrow" width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <path
        d="M2 8h11M9 3.5 13.5 8 9 12.5"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function Button({
  variant = "primary",
  arrow = false,
  loading = false,
  disabled = false,
  forceState,
  href,
  className,
  style,
  children,
}: ButtonProps) {
  const classes = [
    "btn",
    `btn-${variant}`,
    forceState === "hover" ? "is-hover" : "",
    forceState === "focus" ? "is-focus" : "",
    className ?? "",
  ]
    .filter(Boolean)
    .join(" ");

  const content = (
    <>
      <span className="btn-label">{children}</span>
      {arrow && <Arrow />}
      {loading && <Seal size={16} title="" busy className="btn-seal" />}
    </>
  );

  if (href !== undefined) {
    const onClick = (event: MouseEvent<HTMLAnchorElement>) => {
      if (href === "#" || disabled) event.preventDefault();
    };
    return (
      <a
        href={href}
        className={classes}
        style={style}
        onClick={onClick}
        aria-busy={loading || undefined}
        aria-disabled={disabled || undefined}
        tabIndex={disabled ? -1 : undefined}
        data-loading={loading || undefined}
      >
        {content}
      </a>
    );
  }

  return (
    <button
      type="button"
      className={classes}
      style={style}
      disabled={disabled}
      aria-busy={loading || undefined}
      data-loading={loading || undefined}
    >
      {content}
    </button>
  );
}
