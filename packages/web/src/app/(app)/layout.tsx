import type { ReactNode } from "react";
import { AppProviders } from "../../components/app/AppProviders";
import "../../components/app/app.css";
import { BtcStrip } from "../../components/app/BtcStrip";
import { ConnectModal } from "../../components/app/ConnectModal";
import { Toasts } from "../../components/app/Toasts";
import { TopBar } from "../../components/app/TopBar";

// Every screen that talks to a wallet lives under this layout, so the wallet layer loads for these routes only.
export default function AppLayout({ children }: { children: ReactNode }) {
  return (
    <AppProviders>
      <div data-type="b" className="app-root">
        <TopBar />
        <BtcStrip />
        <div className="app-main">{children}</div>
        <ConnectModal />
        <Toasts />
      </div>
    </AppProviders>
  );
}
