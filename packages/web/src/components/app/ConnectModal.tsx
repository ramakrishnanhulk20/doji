"use client";

import { useEffect, useRef, useState } from "react";
import { usePathname } from "next/navigation";
import { useConnect } from "wagmi";
import { explainConnectError } from "../../lib/errors";
import { APP_CHAIN_ID, AddNetworkRefusedError, PHONE_WALLET_ID } from "../../lib/wagmi";
import { Seal } from "../Seal";
import { closeConnectModal, useConnectModalOpen } from "./connect-modal-store";

const FOCUSABLE = 'a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])';

// Fixed on purpose: the link must never be built from the page address a visitor typed.
const METAMASK_APP_LINK = "https://metamask.app.link/dapp/www.dojis.site";

export function ConnectModal() {
  const open = useConnectModalOpen();
  const { connectors, connect, isPending, variables, error, reset } = useConnect();
  const pathname = usePathname();
  const dialogRef = useRef<HTMLDivElement>(null);
  const [hasInjected, setHasInjected] = useState(false);
  const [isPhone, setIsPhone] = useState(false);

  useEffect(() => {
    if (!open) return;
    setHasInjected("ethereum" in window);
    setIsPhone(window.matchMedia("(pointer: coarse)").matches);
    reset();
  }, [open, reset]);

  useEffect(() => {
    if (!open) return;
    const dialog = dialogRef.current;
    dialog?.querySelector<HTMLElement>(FOCUSABLE)?.focus();

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeConnectModal();
        return;
      }
      if (event.key !== "Tab" || !dialog) return;
      const items = [...dialog.querySelectorAll<HTMLElement>(FOCUSABLE)];
      const first = items[0];
      const last = items[items.length - 1];
      if (!first || !last) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  if (!open) return null;

  // EIP-6963 wallets announce themselves by name and icon. The plain injected connector is only the fallback for a
  // wallet that does not announce.
  const announced = connectors.filter((connector) => connector.id !== "injected" && connector.id !== PHONE_WALLET_ID);
  const wallets = announced.length > 0 ? announced : hasInjected ? connectors.filter((connector) => connector.id === "injected") : [];
  const phoneWallet = connectors.find((connector) => connector.id === PHONE_WALLET_ID);
  const phoneConnecting = phoneWallet !== undefined && isPending && variables?.connector === phoneWallet;

  return (
    <div
      className="modal-overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) closeConnectModal();
      }}
    >
      <div ref={dialogRef} className="modal-card" data-lenis-prevent role="dialog" aria-modal="true" aria-labelledby="connect-title">
        <h2 id="connect-title" className="modal-title display-face">
          Connect a wallet
        </h2>

        {(wallets.length > 0 || phoneWallet) && (
          <ul className="wallet-list">
            {wallets.map((connector) => {
              const connecting = isPending && variables?.connector === connector;
              return (
                <li key={connector.uid}>
                  <button
                    type="button"
                    className="wallet-row"
                    disabled={isPending}
                    onClick={() =>
                      connect({ connector, chainId: APP_CHAIN_ID }, { onSuccess: () => closeConnectModal() })
                    }
                  >
                    <span className="wallet-icon">
                      {connector.icon ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={connector.icon} alt="" width={28} height={28} />
                      ) : (
                        <Seal size={28} title="" />
                      )}
                    </span>
                    <span className="wallet-name">{connector.id === "injected" ? "Browser wallet" : connector.name}</span>
                    {connecting && (
                      <span className="wallet-busy">
                        <Seal size={16} title="" busy />
                        Check your wallet
                      </span>
                    )}
                  </button>
                </li>
              );
            })}
            {phoneWallet && (
              <li>
                <button
                  type="button"
                  className="wallet-row"
                  disabled={isPending}
                  onClick={() =>
                    connect({ connector: phoneWallet, chainId: APP_CHAIN_ID }, { onSuccess: () => closeConnectModal() })
                  }
                >
                  <span className="wallet-icon">
                    {phoneWallet.icon ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={phoneWallet.icon} alt="" width={28} height={28} />
                    ) : (
                      <Seal size={28} title="" />
                    )}
                  </span>
                  <span className="wallet-text">
                    <span className="wallet-name">Phone wallet</span>
                    {!phoneConnecting && (
                      <span className="wallet-sub">{isPhone ? "Open your wallet app" : "Scan a QR code with your phone"}</span>
                    )}
                  </span>
                  {phoneConnecting && (
                    <span className="wallet-busy">
                      <Seal size={16} title="" busy />
                      Check your wallet
                    </span>
                  )}
                </button>
              </li>
            )}
            {phoneWallet && isPhone && wallets.length === 0 && (
              <li>
                <a className="wallet-row" href={`${METAMASK_APP_LINK}${pathname}`}>
                  <span className="wallet-icon">
                    <Seal size={28} title="" />
                  </span>
                  <span className="wallet-text">
                    <span className="wallet-name">Open in MetaMask app</span>
                    <span className="wallet-sub">Opens Doji inside MetaMask</span>
                  </span>
                </a>
              </li>
            )}
          </ul>
        )}

        {wallets.length === 0 && (
          <p className="modal-empty">
            {phoneWallet ? "Or install a browser wallet:" : "No browser wallet found. Install"}{" "}
            <a className="link-draw" href="https://metamask.io" target="_blank" rel="noopener noreferrer">
              MetaMask
            </a>{" "}
            or{" "}
            <a className="link-draw" href="https://rabby.io" target="_blank" rel="noopener noreferrer">
              Rabby
            </a>
            , then reload this page.
          </p>
        )}

        {error && (
          <p className="modal-error">{error instanceof AddNetworkRefusedError ? error.message : explainConnectError(error)}</p>
        )}

        <p className="modal-foot">Doji runs on Mezo testnet. Your wallet adds it automatically.</p>
      </div>
    </div>
  );
}
