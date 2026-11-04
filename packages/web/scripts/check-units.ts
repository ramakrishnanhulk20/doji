import { createPublicClient, formatUnits, http, parseUnits } from "viem";
import { mezoTestnetChain } from "../src/lib/chains";
import { formatDate } from "../src/lib/stats";
import { listingStage, quoteBuy, readListings, readMarketSettings, unitYield } from "../src/lib/units";

// Read-only: every call below is a view, and no key is involved.
const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) });
const amount = (value: bigint) => formatUnits(value, 18);
const now = Math.floor(Date.now() / 1000);

const listings = await readListings(client);
console.log(`readListings: ${listings.length} listing(s) with units left`);
for (const listing of listings) {
  console.log(
    `  #${listing.id} seller ${listing.seller} maturity ${listing.maturity} (${formatDate(listing.maturity)}) expiry ${listing.expiry} (${formatDate(listing.expiry)}) fee ${listing.feeBps} bps units left ${amount(listing.unitsLeft)} price ${amount(listing.pricePerUnit)}`,
  );
}

const settings = await readMarketSettings(client);
console.log(`readMarketSettings: feeBps ${settings.feeBps}, paused ${settings.paused}`);

const first = listings.find((listing) => listing.id === 1n);
if (first === undefined) {
  console.log("listing 1 has no units left, so there is nothing to quote");
} else {
  const quote = await quoteBuy(client, first.id, parseUnits("1", 18));
  console.log(`quoteBuy(1, 1 unit): cost ${amount(quote.cost)} MUSD, fee ${amount(quote.fee)} MUSD`);

  const earned = unitYield(first.pricePerUnit, first.maturity, now);
  console.log(
    `unitYield(listing 1) at ${now}: ${earned.toMaturityPct.toFixed(2)}% by ${formatDate(first.maturity)}, about ${earned.perYearPct.toFixed(1)}% a year`,
  );

  console.log(`listingStage(listing 1) now ${now}: ${listingStage(first, now)}`);
  console.log(`listingStage(listing 1) at its maturity ${first.maturity}: ${listingStage(first, first.maturity)}`);
  console.log(`listingStage(listing 1) at its expiry ${first.expiry}: ${listingStage(first, first.expiry)}`);
  // Listing 1 closes the day before its Thursday, so it is already expired there. A copy that stays open a day past
  // the Thursday shows the dated stage, which UnitMarket allows because it never ties expiry to maturity.
  const lateExpiry = { ...first, expiry: first.maturity + 86_400 };
  console.log(`listingStage(copy of listing 1, expiry ${lateExpiry.expiry}) at its maturity: ${listingStage(lateExpiry, first.maturity)}`);
}
