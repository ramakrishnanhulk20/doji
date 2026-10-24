"use client";

import { useQuery } from "@tanstack/react-query";
import Link from "next/link";
import type { ReactNode } from "react";
import { createPublicClient, formatUnits, http, type Address } from "viem";
import { useDemoLoan } from "../../hooks/useDemoLoan";
import { useLiveStats } from "../../hooks/useLiveStats";
import { addressBook, demoLoan } from "../../lib/addresses";
import { readPrice } from "../../lib/borrow-reads";
import { mezoTestnetChain } from "../../lib/chains";
import { formatBtc, formatMusd } from "../../lib/stats";
import { ArrowOut } from "../ArrowOut";
import { SectionHeading } from "../landing/SectionHeading";

// Mezo testnet PoolsVoter; the deployment record does not carry it.
const POOLS_VOTER: Address = "0x72F8dd7F44fFa19E45955aa20A5486E8EB255738";
const EXPLORER_ADDRESS = "https://explorer.test.mezo.org/address/";
const MAINNET_EXPLORER_ADDRESS = "https://explorer.mezo.org/address/";

// The landing page has no wallet layer, so the price is read with a plain client instead of wagmi's.
const testnetClient = createPublicClient({ chain: mezoTestnetChain, transport: http() });

type Figure = { text: string; unavailable: boolean };

// An errored query shows "unavailable" even if an older value is cached: the oracle in particular refuses stale prices.
function readFigure<T>(query: { data: T | undefined; isError: boolean }, format: (data: T) => string): Figure {
  if (query.isError) return { text: "unavailable", unavailable: true };
  if (query.data === undefined) return { text: "...", unavailable: false };
  return { text: format(query.data), unavailable: false };
}

type FigureTextProps = { figure: Figure };

function FigureText({ figure }: FigureTextProps) {
  return <p className={figure.unavailable ? "mezo-figure is-unavailable" : "mezo-figure"}>{figure.text}</p>;
}

type ExplorerLinkProps = { href: string; children: ReactNode };

function ExplorerLink({ href, children }: ExplorerLinkProps) {
  return (
    <a className="link-draw proof-link" href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <ArrowOut />
    </a>
  );
}

export function BuiltOnMezo() {
  const { locked, offers } = useLiveStats();
  const { state } = useDemoLoan();
  const price = useQuery({
    queryKey: ["oracle-price"],
    queryFn: () => readPrice(testnetClient),
    refetchInterval: 15_000,
    retry: false,
  });

  const book = addressBook[31611];

  return (
    <section id="mezo" className="section">
      <div className="section-inner">
        <SectionHeading
          label="Built on Mezo"
          title="Built on Mezo, not next to it."
          body="Doji adds fixed-rate credit on top of Mezo. The lock, the votes, the rewards, the money and the price all stay Mezo's own."
        />

        <ul className="proof-grid">
          <li className="proof-card">
            <p className="label-mono">The collateral</p>
            <h3 className="proof-title">veBTC</h3>
            <FigureText figure={readFigure(locked, (data) => `${formatBtc(data.btc)} BTC`)} />
            <p className="mezo-figure-note">locked as veBTC on Mezo mainnet</p>
            <p className="proof-body">
              Doji holds the position while a loan is open. The lock keeps running and Doji never ends it early.
            </p>
            <ExplorerLink href={`${MAINNET_EXPLORER_ADDRESS}${addressBook[31612].veBTC}`}>
              veBTC on Mezo mainnet
            </ExplorerLink>
          </li>

          <li className="proof-card">
            <p className="label-mono">The votes</p>
            <h3 className="proof-title">PoolsVoter</h3>
            <FigureText figure={readFigure(state, (data) => (data.voted ? "Voting" : "Not voting"))} />
            <p className="mezo-figure-note">veBTC #{demoLoan.tokenId.toString()}, read live</p>
            <p className="proof-body">
              The borrower keeps voting on Mezo&apos;s pools through Doji. Votes are cleared only when a loan has to be
              settled.
            </p>
            <ExplorerLink href={`${EXPLORER_ADDRESS}${POOLS_VOTER}`}>PoolsVoter on the explorer</ExplorerLink>
          </li>

          <li className="proof-card">
            <p className="label-mono">The rewards</p>
            <h3 className="proof-title">Fee distributor</h3>
            <FigureText figure={readFigure(state, (data) => `${data.claimableBtc.toFixed(4)} BTC`)} />
            <p className="mezo-figure-note">rebase waiting for veBTC #{demoLoan.tokenId.toString()}</p>
            <p className="proof-body">
              The veBTC rebase and pool rewards are claimed through Doji and paid to the borrower, never kept by Doji.
            </p>
            <ExplorerLink href={`${EXPLORER_ADDRESS}${book.feeDistributor}`}>Fee distributor on the explorer</ExplorerLink>
          </li>

          <li className="proof-card">
            <p className="label-mono">The loan</p>
            <h3 className="proof-title">MUSD</h3>
            <FigureText figure={readFigure(offers, (data) => `${formatMusd(data.musdOnOffer)} MUSD`)} />
            <p className="mezo-figure-note">on offer from lenders now</p>
            <p className="proof-body">
              Borrowers receive MUSD at once. Lenders post MUSD at their own fixed rate and are paid back in MUSD on
              the date.
            </p>
            <ExplorerLink href={`${EXPLORER_ADDRESS}${book.musd}`}>MUSD on the explorer</ExplorerLink>
          </li>

          <li className="proof-card">
            <p className="label-mono">The price</p>
            <h3 className="proof-title">PriceFeed</h3>
            <FigureText
              figure={readFigure(price, (data) => `${formatMusd(Number(formatUnits(data, 18)))} MUSD`)}
            />
            <p className="mezo-figure-note">per BTC, from MUSD&apos;s own price feed</p>
            <p className="proof-body">
              Every borrow limit, auction line, auction price and settle reads this feed, and a price older than 60
              seconds is refused.
            </p>
            <ExplorerLink href={`${EXPLORER_ADDRESS}${book.priceFeed}`}>PriceFeed on the explorer</ExplorerLink>
          </li>
        </ul>

        <p className="section-body mezo-more">
          <Link className="link-draw" href="/docs/mezo">
            Every Mezo call Doji makes, with testnet and mainnet addresses
          </Link>
        </p>
      </div>
    </section>
  );
}
