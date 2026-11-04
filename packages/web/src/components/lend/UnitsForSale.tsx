"use client";

import { useState } from "react";
import { motion } from "motion/react";
import type { Address } from "viem";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useUnitMarket } from "../../hooks/useUnitMarket";
import { useWrite } from "../../hooks/useWrite";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatDate } from "../../lib/stats";
import {
  MARKET_PAUSED_LINE,
  cancelListingCall,
  fmtUnitsAmount,
  fmtPrice,
  listingStage,
  returnExpiredCall,
  unitYield,
  type Listing,
  type UnitCall,
} from "../../lib/units";
import { Button } from "../Button";
import { BuySheet } from "./BuySheet";

const shortAddress = (address: string) => `${address.slice(0, 6)}...${address.slice(-4)}`;
const sameAddress = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

type CardProps = {
  listing: Listing;
  index: number;
  now: number;
  wallet: Address | undefined;
  connected: boolean;
  paused: boolean;
  disabled: boolean;
  runningKey: string | null;
  reduced: boolean;
  onBuy: () => void;
  onConnect: () => void;
  onCancel: () => void;
  onReturn: () => void;
};

function ListingCard({ listing, index, now, wallet, connected, paused, disabled, runningKey, reduced, onBuy, onConnect, onCancel, onReturn }: CardProps) {
  const date = formatDate(listing.maturity);
  const stage = listingStage(listing, now);
  const expired = stage === "expired";
  // An expired listing can be past its Thursday too, and then it promises no yield either.
  const pastDate = stage === "dated" || (expired && listing.maturity <= now);
  const mine = wallet !== undefined && sameAddress(listing.seller, wallet);
  const yieldNow = unitYield(listing.pricePerUnit, listing.maturity, now);

  return (
    <motion.div
      className="units-cell"
      initial={reduced ? false : { opacity: 0, y: 12 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true }}
      transition={{ duration: 0.4, delay: reduced ? 0 : Math.min(index, 8) * 0.06, ease: [0.22, 1, 0.36, 1] }}
    >
      <article className="units-card" data-reduced={reduced}>
        <h3 className="units-card-date display-face">{date}</h3>
        <p className="units-card-price">
          <span className="units-card-price-value">{fmtPrice(listing.pricePerUnit)}</span>
          <span className="units-card-price-unit"> MUSD a unit</span>
        </p>
        {pastDate ? (
          <p className="units-card-dated">
            This date has passed. A unit now pays what its loans returned, shown in Your credit units.
          </p>
        ) : (
          <p className="units-card-yield">
            Earns {yieldNow.toMaturityPct.toFixed(2)}% by {date} · about {yieldNow.perYearPct.toFixed(1)}% a year
          </p>
        )}
        <div className="units-card-facts">
          <p>{fmtUnitsAmount(listing.unitsLeft)} units left</p>
          <p>
            Listing #{listing.id.toString()} ·{" "}
            {expired ? `closed for buying on ${formatDate(listing.expiry)}` : `open until ${formatDate(listing.expiry)}`}
          </p>
          {mine ? (
            <p>
              <span className="units-card-tag">Your listing</span>
            </p>
          ) : (
            <p>Seller {shortAddress(listing.seller)}</p>
          )}
        </div>
        {(mine || stage !== "dated") && (
          <div className="units-card-action">
            {mine ? (
              <Button variant="secondary" className="units-card-button" disabled={disabled} loading={runningKey === `cancel:${listing.id}`} onClick={onCancel}>
                Cancel listing
              </Button>
            ) : expired ? (
              <Button variant="secondary" className="units-card-button" disabled={disabled} loading={runningKey === `return:${listing.id}`} onClick={connected ? onReturn : onConnect}>
                Return to seller
              </Button>
            ) : (
              <Button className="units-card-button" disabled={paused || disabled} onClick={connected ? onBuy : onConnect}>
                {connected ? "Buy units" : "Connect a wallet to buy"}
              </Button>
            )}
          </div>
        )}
      </article>
    </motion.div>
  );
}

/** The listings anyone can buy from, and the cancel and return actions on them. Reads work without a wallet. */
export function UnitsForSale({ now, busy }: { now: number; busy: boolean }) {
  const { listings, settings } = useUnitMarket();
  const gate = useLoanGate();
  const { write, busy: writing } = useWrite();
  const reduced = useReducedMotion();
  const [buyingId, setBuyingId] = useState<bigint | null>(null);
  const [runningKey, setRunningKey] = useState<string | null>(null);

  const paused = settings.data?.paused === true;
  const disabled = busy || writing;
  const rows = listings.data ?? [];
  const buying = buyingId === null ? null : (rows.find((row) => row.id === buyingId) ?? null);

  const run = async (key: string, call: UnitCall, successLine: string) => {
    setRunningKey(key);
    await write({ ...call, successLine });
    setRunningKey(null);
  };

  return (
    <>
      <p className="units-lead">
        A credit unit pays 1 MUSD once the loans of its Thursday are repaid. Lenders who want their MUSD sooner sell units
        here below 1 MUSD, and the buyer keeps the difference.
      </p>

      {paused && <p className="paused-strip">{MARKET_PAUSED_LINE}</p>}

      {listings.isError ? (
        <p className="units-note">The units market could not be read right now. Doji is trying again.</p>
      ) : listings.data === undefined ? (
        <div className="units-grid" aria-busy="true">
          {[0, 1, 2].map((slot) => (
            <span key={slot} className="units-skeleton shimmer" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <p className="units-note">No units are listed right now. Lenders list them from Your credit units below.</p>
      ) : (
        <div className="units-grid">
          {rows.map((listing, index) => (
            <ListingCard
              key={listing.id.toString()}
              listing={listing}
              index={index}
              now={now}
              wallet={gate.address}
              connected={gate.isConnected}
              paused={paused}
              disabled={disabled}
              runningKey={runningKey}
              reduced={reduced}
              onBuy={() => setBuyingId(listing.id)}
              onConnect={gate.connect}
              onCancel={() =>
                void run(
                  `cancel:${listing.id}`,
                  cancelListingCall(listing.id),
                  `Listing #${listing.id} cancelled. ${fmtUnitsAmount(listing.unitsLeft)} units are back in your wallet.`,
                )
              }
              onReturn={() =>
                void run(
                  `return:${listing.id}`,
                  returnExpiredCall(listing.id),
                  `Listing #${listing.id} closed. Its ${fmtUnitsAmount(listing.unitsLeft)} units went back to the seller.`,
                )
              }
            />
          ))}
        </div>
      )}

      {buying !== null && <BuySheet listing={buying} now={now} paused={paused} onClose={() => setBuyingId(null)} />}
    </>
  );
}
