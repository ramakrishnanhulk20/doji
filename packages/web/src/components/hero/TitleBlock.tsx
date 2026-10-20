import { cssVars } from "../../lib/css-vars";
import { Button } from "../Button";
import { EYEBROW, HEADLINES, SUBLINE, type HeadlineChoice } from "./copy";

const WORDMARK = ["D", "o", "j", "i"] as const;

export function TitleBlock({ headline }: { headline: HeadlineChoice }) {
  return (
    <div className="title-block">
      <p className="eyebrow label-mono enter" style={cssVars({ "--delay": "500ms" })}>
        {EYEBROW}
      </p>
      <p className="wordmark display-face">
        <span className="sr-only">Doji</span>
        <span className="wordmark-line" aria-hidden="true">
          {WORDMARK.map((letter, index) => (
            <span key={index} className="wordmark-letter" style={cssVars({ "--i": index })}>
              {letter}
            </span>
          ))}
        </span>
      </p>
      <h1 className="headline display-face">
        {HEADLINES[headline].map((line, index) => (
          <span
            key={index}
            className="headline-line enter"
            style={cssVars({ "--delay": `${1000 + index * 90}ms` })}
          >
            {line}
          </span>
        ))}
      </h1>
      <p className="subline enter" style={cssVars({ "--delay": "1300ms" })}>
        {SUBLINE}
      </p>
      <div className="hero-actions">
        <Button href="/borrow" arrow className="enter" style={cssVars({ "--delay": "1380ms" })}>
          Borrow MUSD
        </Button>
        <Button href="/lend" variant="secondary" className="enter" style={cssVars({ "--delay": "1460ms" })}>
          Lend MUSD
        </Button>
      </div>
    </div>
  );
}
