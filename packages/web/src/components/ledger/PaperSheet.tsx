import type { CSSProperties, ReactNode } from "react";
import "./ledger.css";

type PaperSheetProps = {
  children?: ReactNode;
  className?: string;
  style?: CSSProperties;
};

// Edges stay straight with a 2px radius: paper never gets rounded cards.
export function PaperSheet({ children, className, style }: PaperSheetProps) {
  return (
    <div className={className ? `ledger-paper ${className}` : "ledger-paper"} style={style}>
      {children}
    </div>
  );
}
