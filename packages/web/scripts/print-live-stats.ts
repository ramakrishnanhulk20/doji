import {
  formatApr,
  formatBlock,
  formatBtc,
  formatDate,
  formatMusd,
  formatUsdCompact,
  readBlock,
  readMezoLocked,
  readOffers,
} from "../src/lib/stats";

const [locked, offers, block] = await Promise.all([readMezoLocked(), readOffers(), readBlock()]);

const usd = locked.usd === null ? "oracle price unavailable" : `≈ ${formatUsdCompact(locked.usd)}`;
console.log(`locked ${formatBtc(locked.btc)} BTC (${usd})`);
console.log(`on offer ${formatMusd(offers.musdOnOffer)} MUSD`);
console.log(
  offers.best === null
    ? "best no open offers"
    : `best ${formatApr(offers.best.aprBps / 100)} to ${formatDate(offers.best.maturity)}`,
);
console.log(`block ${formatBlock(block)}`);
