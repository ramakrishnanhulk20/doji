"use client";

import { btcText, musdText, type Claimables } from "../../lib/loans";
import { Button } from "../Button";

type ClaimStripProps = {
  claimables: Claimables;
  disabled: boolean;
  loading: boolean;
  onClaim: () => void;
};

/** What auctions and settlements left for this wallet, with the button that collects it. */
export function ClaimStrip({ claimables, disabled, loading, onClaim }: ClaimStripProps) {
  return (
    <section className="claim-strip" aria-label="Waiting for you">
      <p className="claim-strip-text">
        Waiting for you: {musdText(claimables.musd)} MUSD and {btcText(claimables.btc)} BTC from auctions or settlements.
      </p>
      <Button className="loan-btn" disabled={disabled} loading={loading} onClick={onClaim}>
        Claim
      </Button>
    </section>
  );
}
