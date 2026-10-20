import {
  formatApr,
  formatBlock,
  formatBtc,
  formatDate,
  formatHours,
  formatMusd,
  formatPercentBps,
  formatUsdCompact,
  readBlock,
  readDemoLoan,
  readMezoLocked,
  readOffers,
  readOpenAuctions,
  readRiskSettings,
  readThursdayBoard,
} from "../src/lib/stats";
import { demoLoan } from "../src/lib/addresses";

const [locked, offers, block, loan] = await Promise.all([readMezoLocked(), readOffers(), readBlock(), readDemoLoan()]);

const usd = locked.usd === null ? "oracle price unavailable" : `≈ ${formatUsdCompact(locked.usd)}`;
console.log(`locked ${formatBtc(locked.btc)} BTC (${usd})`);
console.log(`on offer ${formatMusd(offers.musdOnOffer)} MUSD`);
console.log(
  offers.best === null
    ? "best no open offers"
    : `best ${formatApr(offers.best.aprBps / 100)} to ${formatDate(offers.best.maturity)}`,
);
console.log(`block ${formatBlock(block)}`);

const lock = loan.isPermanent ? "locked permanently" : `locked until ${formatDate(loan.lockEnd)}`;
const votes = loan.voted ? "votes still counting" : "votes yours to cast";
const rewards = loan.claimableBtc > 0 ? `rewards ${loan.claimableBtc.toFixed(6)} BTC waiting` : "rewards none due yet";
console.log(`loan ${demoLoan.tokenId}: ${loan.active ? "active" : "closed"}, ${lock}, ${votes}, ${rewards}, borrowed ${formatMusd(loan.principal)} MUSD`);

const [risk, board, auctions] = await Promise.all([
  readRiskSettings(),
  readThursdayBoard(Math.floor(Date.now() / 1000)),
  readOpenAuctions(),
]);

console.log(
  `limits ${formatPercentBps(risk.maxLtvBps)} / ${formatPercentBps(risk.liqLtvBps)} / floor ${formatPercentBps(risk.auctionFloorBps)} / ${formatHours(risk.auctionDuration)} / penalty ${formatPercentBps(risk.penaltyBps)}`,
);
for (const card of board) {
  const rate = card.bestAprBps === null ? "no offers" : `best ${formatApr(card.bestAprBps / 100)}`;
  console.log(
    `${formatDate(card.maturity)}: ${rate}, on offer ${formatMusd(card.musdOnOffer)} MUSD in ${card.offerCount} offers, lent ${formatMusd(card.lent)} MUSD, ${card.openLoans} open loans`,
  );
}
console.log(
  auctions.length === 0
    ? "auctions open: 0"
    : `auctions open: ${auctions.length} (${auctions.map((a) => `loan ${a.tokenId} at ${formatMusd(a.price)} MUSD`).join(", ")})`,
);
