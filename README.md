# Doji

Doji (同時) means "at the same time": your Bitcoin stays locked and earning while you borrow against it. The name also nods to the doji candlestick, which comes from the 18th-century rice traders of Osaka's Dojima exchange, who traded fixed-date claims on rice held in storehouses.

Doji lets people who lock Bitcoin on [Mezo](https://mezo.org) as veBTC borrow MUSD against it at a fixed rate until a fixed date, without ending the lock or losing the rewards. Lenders post offers for a date and a rate, and receive credit units for that date that they can transfer before it arrives.

Status: being built for the Mezo Buildathon (Wave 1 closes 26 October 2026). Nothing here is deployed yet.

- Security design, written before any contract code: [docs/security/threat-model.md](docs/security/threat-model.md)
- Contracts: [packages/contracts](packages/contracts) (Foundry, Solidity 0.8.28)
