import { Seal } from "../Seal";
import { CARTOUCHE_LABEL, PRINT_ALT, PRINT_SIZES, PRINT_SOURCES } from "./copy";

export function PrintStage() {
  return (
    <div className="print-stage">
      <div className="stage-motion">
        <picture>
          <source type="image/avif" srcSet={PRINT_SOURCES.avif} sizes={PRINT_SIZES} />
          <source type="image/webp" srcSet={PRINT_SOURCES.webp} sizes={PRINT_SIZES} />
          <img
            className="print-image"
            src="/art/dojima-1600.jpg"
            alt={PRINT_ALT}
            width={2400}
            height={1004}
            fetchPriority="high"
            decoding="async"
          />
        </picture>
        <div className="cartouche" role="img" aria-label={CARTOUCHE_LABEL}>
          <span className="cartouche-text" lang="ja" aria-hidden="true">
            同時
          </span>
          <Seal size={24} title="" className="cartouche-seal" />
        </div>
      </div>
    </div>
  );
}
