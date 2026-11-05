import { PHONE_WALLET_ID, wagmiConfig } from "../src/lib/wagmi";

// Offline: nothing here reaches the network or a wallet. Run it twice to cover both setups:
//   NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=check npx tsx scripts/check-walletconnect.ts
//   npx tsx scripts/check-walletconnect.ts
const expectPhoneWallet = Boolean(process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID);
const failures: string[] = [];
const check = (name: string, passed: boolean) => {
  console.log(`${passed ? "ok  " : "FAIL"} ${name}`);
  if (!passed) failures.push(name);
};

const ids = wagmiConfig.connectors.map((connector) => connector.id);
const phone = wagmiConfig.connectors.find((connector) => connector.id === PHONE_WALLET_ID);

check(`browser wallet connector is present (connectors: ${ids.join(", ")})`, ids.includes("injected"));
check(
  expectPhoneWallet ? "phone wallet connector is present when the project ID is set" : "phone wallet connector is absent without a project ID",
  expectPhoneWallet ? phone !== undefined : phone === undefined,
);

if (phone) {
  // Reconnecting on page load asks every connector for its provider. An unpicked phone wallet must answer with
  // nothing, which is what keeps WalletConnect's code from loading on every visit.
  check("provider stays unloaded before the person picks the row", (await phone.getProvider()) === undefined);
  check("a connector that was never picked is not authorized", (await phone.isAuthorized()) === false);
}

if (failures.length > 0) {
  console.error(`\n${failures.length} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
