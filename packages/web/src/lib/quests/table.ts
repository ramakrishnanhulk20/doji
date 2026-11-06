import { parseAbiItem, toEventSelector, type AbiEvent, type Address, type Hex } from "viem";
import { parseAddress } from "../address";
import { addressBook, wave2Pair } from "../addresses";
import type { DecodedLog } from "./logs";

// The only place quests exist (C68). What is not in this file earns nothing. Changing a row here is a public commit, so
// anyone can rebuild a wallet's EXP from this repo and the chain (C69).

const book = addressBook[31611];

function bookAddress(value: unknown): Address {
  const address = parseAddress(value);
  if (address === null) throw new Error("the address book holds something that is not an address");
  return address;
}

/** The only contracts whose logs can earn EXP (C67). */
export const CONTRACTS = {
  faucet: bookAddress(book.faucet),
  loanManager: bookAddress(book.loanManager),
  creditMarkets: bookAddress(book.creditMarkets),
  payDown: bookAddress(book.payDown),
  unitMarket: bookAddress(book.unitMarket),
  poolsVoter: bookAddress(book.poolsVoter),
} as const;

export type ContractKey = keyof typeof CONTRACTS;

/** A log older than the Wave 2 deploy counts for nothing, whoever emitted it (C67). */
export const FROM_BLOCK = Number(wave2Pair.fromBlock);

/** The most EXP one bonus entry can carry. scripts/validate-bonus.mjs refuses anything above it (C74). */
export const BONUS_EXP_CAP = 1_000;

type EventSpec = {
  contract: ContractKey;
  abi: AbiEvent;
  /** The indexed fields that name a wallet. A wallet comes from these, never from the transaction's sender (C68). */
  wallets: readonly string[];
  /** The indexed id a one-wallet read follows this event by, for an event that does not name the wallet itself. */
  id?: string;
  /** Narrows the all-wallets scan. PoolsVoter is Mezo's, so without this anyone's votes would count against the page cap. */
  scan?: { field: string; wallet: Address };
};

const spec = (contract: ContractKey, signature: string, fields: Partial<Omit<EventSpec, "contract" | "abi">> = {}): EventSpec => ({
  contract,
  abi: parseAbiItem(signature) as AbiEvent,
  wallets: [],
  ...fields,
});

const specs = {
  Claimed: spec("faucet", "event Claimed(address indexed to, uint256 btc, uint256 musd, uint256 indexed day)", { wallets: ["to"] }),
  Deposited: spec("loanManager", "event Deposited(uint256 indexed tokenId, address indexed borrower)", { wallets: ["borrower"] }),
  Borrowed: spec(
    "loanManager",
    "event Borrowed(uint256 indexed tokenId, address indexed borrower, uint64 indexed maturity, uint256 principal, uint256 face)",
    { wallets: ["borrower"] },
  ),
  Repaid: spec("loanManager", "event Repaid(uint256 indexed tokenId, address indexed payer, uint256 amount, uint256 owedAfter)", {
    wallets: ["payer"],
  }),
  Withdrawn: spec("loanManager", "event Withdrawn(uint256 indexed tokenId, address indexed borrower)", { wallets: ["borrower"] }),
  Purchased: spec(
    "loanManager",
    "event Purchased(uint256 indexed tokenId, address indexed buyer, address indexed borrower, uint256 price, uint256 toMarket, uint256 toTreasury, uint256 toBorrower)",
    { wallets: ["buyer", "borrower"] },
  ),
  Settled: spec(
    "loanManager",
    "event Settled(uint256 indexed tokenId, address indexed borrower, uint256 btcReceived, uint256 btcPrice, uint256 toMarket, uint256 toTreasury, uint256 toBorrower)",
    { wallets: ["borrower"] },
  ),
  RewardOperatorSet: spec("loanManager", "event RewardOperatorSet(uint256 indexed tokenId, address indexed operator)", { id: "tokenId" }),
  Rolled: spec(
    "loanManager",
    "event Rolled(uint256 indexed tokenId, uint64 indexed oldMaturity, uint64 indexed newMaturity, uint256 oldOwed, uint256 excessPaid, uint256 topUp)",
    { id: "tokenId" },
  ),
  OfferPosted: spec(
    "creditMarkets",
    "event OfferPosted(uint256 indexed offerId, address indexed maker, uint64 indexed maturity, uint16 aprBps, uint128 amount)",
    { wallets: ["maker"] },
  ),
  OfferParked: spec("creditMarkets", "event OfferParked(uint256 indexed offerId, uint128 amount)", { id: "offerId" }),
  Filled: spec(
    "creditMarkets",
    "event Filled(uint256 indexed offerId, address indexed maker, uint64 indexed maturity, uint256 principal, uint256 face)",
    { wallets: ["maker"] },
  ),
  UnitsClaimed: spec("creditMarkets", "event UnitsClaimed(address indexed account, uint64 indexed maturity, uint256 units)", {
    wallets: ["account"],
  }),
  Redeemed: spec(
    "creditMarkets",
    "event Redeemed(address indexed account, uint64 indexed maturity, uint256 units, uint256 musdOut, uint256 btcOut)",
    { wallets: ["account"] },
  ),
  CollectedWithdrawn: spec(
    "creditMarkets",
    "event CollectedWithdrawn(address indexed account, uint64 indexed maturity, uint256 unitsAdded, uint256 musdOut, uint256 btcOut)",
    { wallets: ["account"] },
  ),
  Listed: spec(
    "unitMarket",
    "event Listed(uint256 indexed listingId, address indexed seller, uint64 indexed maturity, uint128 units, uint128 pricePerUnit, uint64 expiry, uint16 feeBps)",
    { wallets: ["seller"], id: "listingId" },
  ),
  Bought: spec("unitMarket", "event Bought(uint256 indexed listingId, address indexed buyer, uint128 units, uint256 cost, uint256 fee)", {
    wallets: ["buyer"],
  }),
  Harvested: spec(
    "payDown",
    "event Harvested(uint256 indexed tokenId, address indexed caller, uint256 musdRepaid, uint256 btcSold, uint256 musdFromBtc)",
    { wallets: ["caller"] },
  ),
  Voted: spec(
    "poolsVoter",
    "event Voted(address indexed voter, address indexed pool, uint256 indexed tokenId, uint256 weight, uint256 totalWeight, uint256 timestamp)",
    { id: "tokenId", scan: { field: "voter", wallet: CONTRACTS.loanManager } },
  ),
};

export type EventName = keyof typeof specs;
export type QuestEvent = EventSpec & { name: EventName; topic0: Hex };

export const EVENTS = Object.fromEntries(
  (Object.entries(specs) as [EventName, EventSpec][]).map(([name, event]) => [name, { ...event, name, topic0: toEventSelector(event.abi) }]),
) as Record<EventName, QuestEvent>;

export const QUEST_EVENTS: readonly QuestEvent[] = Object.values(EVENTS);

const eventsByLog = new Map(QUEST_EVENTS.map((event) => [`${CONTRACTS[event.contract]}:${event.topic0}`, event]));

/**
 * The table event this emitter and first topic mean, or undefined when the pair is not in the table. Two contracts may
 * emit one signature, and Faucet and LoanManager both have a Withdrawn, so the pair decides, never the name.
 */
export const eventAt = (emitter: Address, topic0: Hex | undefined): QuestEvent | undefined =>
  eventsByLog.get(`${emitter}:${topic0}`);

/** Which topic of an event holds an indexed field: topic 1 is the first indexed field. */
export function topicOf(event: QuestEvent, field: string): 1 | 2 | 3 {
  const place = event.abi.inputs.filter((input) => input.indexed).findIndex((input) => input.name === field) + 1;
  if (place < 1 || place > 3) throw new Error(`${event.name} has no indexed field ${field}`);
  return place as 1 | 2 | 3;
}

export type Chapter = "first" | "lender" | "thursday" | "hard";

/** What a row's extra condition can ask of the logs. All of it comes from logs, never from a view (C68). */
export type QuestFacts = {
  wallet: Address;
  offerParked(offerId: bigint): boolean;
  sellerOf(listingId: bigint): Address | null;
  borrowersIn(hash: Hex): readonly Address[];
};

type Proof = {
  event: EventName;
  /** The field that must equal the wallet. Left out when the wallet is reached through the position in `tokenId`. */
  wallet?: string;
  /** The log's tokenId must have been held by the wallet at that block. */
  held?: boolean;
  also?: (seen: DecodedLog, facts: QuestFacts) => boolean;
};

/**
 * F45 extended: a quest that names a payment or a transfer counts only if at least one of these amounts is above zero.
 * Most of these contracts refuse an empty call today, and this holds the row to its name whatever they do.
 */
const moved = ({ args }: DecodedLog, ...amounts: readonly string[]): boolean => amounts.some((field) => (args[field] as bigint) > 0n);

export type QuestId =
  | "kit"
  | "borrow"
  | "vote"
  | "paydown"
  | "repay"
  | "home"
  | "parked"
  | "stranger"
  | "units"
  | "sell"
  | "buy"
  | "payout"
  | "harvest"
  | "roll"
  | "auction"
  | "bug";

export type Quest = { id: QuestId; chapter: Chapter; exp: number; kanji: string; proofs: readonly Proof[] };

export const QUESTS: readonly Quest[] = [
  { id: "kit", chapter: "first", exp: 50, kanji: "元", proofs: [{ event: "Claimed", wallet: "to", also: (seen) => moved(seen, "btc", "musd") }] },
  { id: "borrow", chapter: "first", exp: 200, kanji: "借", proofs: [{ event: "Borrowed", wallet: "borrower", also: (seen) => moved(seen, "principal") }] },
  {
    id: "vote",
    chapter: "first",
    exp: 100,
    kanji: "票",
    proofs: [{ event: "Voted", held: true, also: ({ args }) => args.voter === CONTRACTS.loanManager }],
  },
  {
    id: "paydown",
    chapter: "first",
    exp: 100,
    kanji: "払",
    proofs: [{ event: "RewardOperatorSet", held: true, also: ({ args }) => args.operator === CONTRACTS.payDown }],
  },
  { id: "repay", chapter: "first", exp: 150, kanji: "返", proofs: [{ event: "Repaid", wallet: "payer", held: true, also: (seen) => moved(seen, "amount") }] },
  { id: "home", chapter: "first", exp: 50, kanji: "戻", proofs: [{ event: "Withdrawn", wallet: "borrower" }] },
  {
    id: "parked",
    chapter: "lender",
    exp: 150,
    kanji: "預",
    proofs: [{ event: "OfferPosted", wallet: "maker", also: (seen, facts) => moved(seen, "amount") && facts.offerParked(seen.args.offerId as bigint) }],
  },
  {
    id: "stranger",
    chapter: "lender",
    exp: 250,
    kanji: "客",
    proofs: [
      {
        event: "Filled",
        wallet: "maker",
        also: (seen, facts) => moved(seen, "principal") && facts.borrowersIn(seen.log.hash).some((borrower) => borrower !== facts.wallet),
      },
    ],
  },
  { id: "units", chapter: "lender", exp: 100, kanji: "券", proofs: [{ event: "UnitsClaimed", wallet: "account", also: (seen) => moved(seen, "units") }] },
  { id: "sell", chapter: "lender", exp: 150, kanji: "売", proofs: [{ event: "Listed", wallet: "seller", also: (seen) => moved(seen, "units") }] },
  {
    id: "buy",
    chapter: "lender",
    exp: 150,
    kanji: "買",
    proofs: [
      {
        event: "Bought",
        wallet: "buyer",
        also: (seen, facts) => {
          const seller = facts.sellerOf(seen.args.listingId as bigint);
          return moved(seen, "cost") && seller !== null && seller !== facts.wallet;
        },
      },
    ],
  },
  {
    id: "payout",
    chapter: "thursday",
    exp: 200,
    kanji: "受",
    // F45: withdrawCollected with nothing collected still emits its event, so a payout of nothing must earn nothing.
    proofs: [
      { event: "Redeemed", wallet: "account", also: (seen) => moved(seen, "musdOut", "btcOut") },
      { event: "CollectedWithdrawn", wallet: "account", also: (seen) => moved(seen, "musdOut", "btcOut") },
    ],
  },
  {
    id: "harvest",
    chapter: "thursday",
    exp: 150,
    kanji: "収",
    // F45: anyone may harvest any loan, so a harvest that repaid nothing must earn nothing.
    proofs: [{ event: "Harvested", wallet: "caller", also: ({ args }) => (args.musdRepaid as bigint) > 0n }],
  },
  { id: "roll", chapter: "thursday", exp: 200, kanji: "転", proofs: [{ event: "Rolled", held: true }] },
  {
    id: "auction",
    chapter: "hard",
    exp: 500,
    kanji: "競",
    proofs: [{ event: "Purchased", wallet: "buyer", also: (seen, facts) => moved(seen, "price") && seen.args.borrower !== facts.wallet }],
  },
  // No log proves this one: it comes from content/quests/bonus-exp.json alone.
  { id: "bug", chapter: "hard", exp: 0, kanji: "虫", proofs: [] },
];
