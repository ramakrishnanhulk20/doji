"use client";

import { useEffect, useRef, useState } from "react";
import { formatUnits } from "viem";
import { useAccount, useBalance, useDisconnect, useSwitchChain } from "wagmi";
import { APP_CHAIN_ID } from "../../lib/wagmi";
import { openConnectModal } from "./connect-modal-store";

const EXPLORER_ADDRESS = "https://explorer.test.mezo.org/address/";

const shortAddress = (address: string) => `${address.slice(0, 6)}...${address.slice(-4)}`;

function ConnectedChip({ address }: { address: `0x${string}` }) {
  const { disconnect } = useDisconnect();
  const balance = useBalance({ address, chainId: APP_CHAIN_ID });
  const [menuOpen, setMenuOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const chipRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!menuOpen) return;
    const closeOnOutside = (event: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(event.target as Node)) setMenuOpen(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setMenuOpen(false);
        chipRef.current?.focus();
      }
    };
    document.addEventListener("mousedown", closeOnOutside);
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("mousedown", closeOnOutside);
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, [menuOpen]);

  const btc = balance.data ? Number(formatUnits(balance.data.value, 18)).toFixed(4) : "...";

  return (
    <div ref={rootRef} className="wallet-chip-root">
      <button
        ref={chipRef}
        type="button"
        className="wallet-chip"
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        onClick={() => setMenuOpen((value) => !value)}
      >
        <span className="net-dot wallet-chip-dot" aria-hidden="true" />
        <span className="wallet-chip-address">{shortAddress(address)}</span>
        <span className="wallet-chip-balance">{btc} BTC</span>
      </button>
      {menuOpen && (
        <div className="wallet-menu" role="menu">
          <button
            type="button"
            role="menuitem"
            className="wallet-menu-item"
            onClick={() => {
              void navigator.clipboard.writeText(address).then(() => setCopied(true));
              window.setTimeout(() => setCopied(false), 1_500);
            }}
          >
            {copied ? "Copied" : "Copy address"}
          </button>
          <a
            role="menuitem"
            className="wallet-menu-item"
            href={`${EXPLORER_ADDRESS}${address}`}
            target="_blank"
            rel="noopener noreferrer"
          >
            View on explorer
          </a>
          <button
            type="button"
            role="menuitem"
            className="wallet-menu-item"
            onClick={() => {
              setMenuOpen(false);
              disconnect();
            }}
          >
            Disconnect
          </button>
        </div>
      )}
    </div>
  );
}

export function WalletButton() {
  const { address, chainId, isConnected } = useAccount();
  const { switchChain, isPending } = useSwitchChain();

  if (!isConnected || !address) {
    return (
      <button type="button" className="wallet-button" onClick={openConnectModal}>
        Connect wallet
      </button>
    );
  }
  if (chainId !== APP_CHAIN_ID) {
    return (
      <button
        type="button"
        className="wallet-button wallet-button-watch"
        disabled={isPending}
        onClick={() => switchChain({ chainId: APP_CHAIN_ID })}
      >
        Switch to Mezo testnet
      </button>
    );
  }
  return <ConnectedChip address={address} />;
}
