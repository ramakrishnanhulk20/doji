import type { ReactNode } from "react";
import { Reveal } from "./Reveal";

type SectionHeadingProps = {
  label: string;
  title: ReactNode;
  body?: string;
};

export function SectionHeading({ label, title, body }: SectionHeadingProps) {
  return (
    <Reveal className="section-heading">
      <p className="label-mono">{label}</p>
      <h2 className="section-title display-face">{title}</h2>
      {body && <p className="section-body">{body}</p>}
    </Reveal>
  );
}
