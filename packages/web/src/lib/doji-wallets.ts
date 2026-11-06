import type { Address } from "viem";
import { parseAddress } from "./address";

// Every wallet Doji controls, in one list (C75). Owner, guardian and treasury on every contract are the deployer today,
// read from the chain on 2026-11-05, so they add no line here. scripts/check-quests.ts fails if a deployment record, a
// wallet in packages/contracts/.env or a role on chain names a wallet this list does not hold. Public addresses only.
const LISTED: readonly string[] = [
  "0xd338Ad588D6c3aE127FD5eEC6843A468d3a7aa6e", // deployer, owner, guardian, treasury
  "0x6EF23DBf6cDa3738f44913595B87A0559746895F", // keeper
  "0x837Fbb9E11f47293fF31F4F79AD5D5E3EC29aEbA", // relayer
  "0x92DcCb70C33300848Da555eDe8597d3F7037AE2b", // seed borrower
  "0xb164F15b59DFd9eb7eac60A364ce3F0f6721A5Ef", // second seed borrower
  "0x56b9c9418baefdedef6da0ab2af450842b776b79", // seed buyer
  "0xCFD41eb3Cd90BB5E8e583182333a8Dc2DB0992B4", // faucet proof claim
  "0xb3a727A0447D2c0168395124cb374a970bDCA524", // claim route proof
  "0xE26ca169c608885406162710AE6731EfBdd41ccA", // first real claim
  "0xd57D8F8A615F35133D8121e58F4ed778A4F612E9", // team test wallet
];

function parsedList(): ReadonlySet<Address> {
  return new Set(
    LISTED.map((entry) => {
      const address = parseAddress(entry);
      if (address === null) throw new Error(`doji-wallets holds something that is not an address: ${entry}`);
      return address;
    }),
  );
}

export const dojiWallets = parsedList();

/**
 * True for a wallet on the list, in any spelling. A display filter for the leaderboard only: it says nothing about a
 * friend's or an insider's wallet.
 */
export function isDojiWallet(value: unknown): boolean {
  const address = parseAddress(value);
  return address !== null && dojiWallets.has(address);
}
