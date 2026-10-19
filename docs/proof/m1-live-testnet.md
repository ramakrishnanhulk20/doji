# Live proof: the core loan on Mezo testnet

Run on 2026-10-19 with the code at commit a800190, on Mezo testnet (chain 31611). Every transaction below succeeded; each link opens it on Mezo's explorer.

Contracts: CreditMarkets [0x8D3C60B17AE7D5f252A0541135B83ede767b258b](https://explorer.test.mezo.org/address/0x8D3C60B17AE7D5f252A0541135B83ede767b258b), LoanManager [0x6Ff8EeC176D01c059c185d8FB4f8485D8B594b9f](https://explorer.test.mezo.org/address/0x6Ff8EeC176D01c059c185d8FB4f8485D8B594b9f). These are the first-slice contracts; the full protocol is deployed later at new addresses.

Result: the borrower borrowed 15 MUSD against a real testnet veBTC position, repaid the fixed 15.0057 MUSD, and holds the position again (owner 0x92DcCb70C33300848Da555eDe8597d3F7037AE2b). The lender's offer has 5 MUSD left.

| # | Who | Step | Transaction |
|---|---|---|---|
| 1 | deployer | Deploy CreditMarkets | [0x5736e7c1...955304](https://explorer.test.mezo.org/tx/0x5736e7c1f18bcce910ad6e5098c09e1f6775d8fe9ba7bdf3651f170e68955304) |
| 2 | deployer | Deploy LoanManager | [0x944c249e...f4ae78](https://explorer.test.mezo.org/tx/0x944c249e98c9dbb794d206a48922b403f6ce54960f43bf8694e93fac7df4ae78) |
| 3 | lender | Approve test BTC for the DEX router | [0xb8ff4faf...505e6b](https://explorer.test.mezo.org/tx/0xb8ff4fafaaf3c5298f190d5b223871035e6ce6ed80af9b2a8f67bdc7b7505e6b) |
| 4 | lender | Swap 0.0003 test BTC to MUSD on Mezo testnet DEX | [0x56ed76b4...f8536b](https://explorer.test.mezo.org/tx/0x56ed76b42afb8baacf998ab2e5aab8ed6122a84979201b9d7a020da62df8536b) |
| 5 | lender | Approve MUSD for CreditMarkets | [0x4c2b5aac...f1026a](https://explorer.test.mezo.org/tx/0x4c2b5aacce5496be8596b385dbcb35e8fb64c1f7337030de1bf12684dff1026a) |
| 6 | lender | Post a fixed-rate offer for Thursday 2026-10-22 | [0xe0584430...abf3ef](https://explorer.test.mezo.org/tx/0xe05844307240ca27d5f1b80e8273f984e059f0f2bb5a9116732804b715abf3ef) |
| 7 | lender (sends BTC for gas to the borrower) | Send test BTC to the borrower for gas | [0x192fc7de...6cad2a](https://explorer.test.mezo.org/tx/0x192fc7deab1a39af24c13a5f109186dd3f044f721722c37d789e8ee4426cad2a) |
| 8 | lender (sends MUSD for interest to the borrower) | Send MUSD to the borrower to cover interest | [0x1dcfe6c5...f0c632](https://explorer.test.mezo.org/tx/0x1dcfe6c52a3b8dc1737f64a2ab2fe06aee04090b10cff04125cf7439aef0c632) |
| 9 | borrower | Approve test BTC for veBTC | [0x7f2a2667...72d8db](https://explorer.test.mezo.org/tx/0x7f2a266742f23e7882613374b5172d04e44c88e413aa3d33b6899feca972d8db) |
| 10 | borrower | Lock 0.001 test BTC as veBTC (lock ends 2026-10-29) | [0xd9d254b5...c891f1](https://explorer.test.mezo.org/tx/0xd9d254b5b02568b3680b7f5d737cc6a7ab2625d5f76462af2c240e1c03c891f1) |
| 11 | borrower | Approve the veBTC position for LoanManager | [0x6f4620d0...a48a82](https://explorer.test.mezo.org/tx/0x6f4620d0b2f5784d75ef3f99ec122267a524f0e569cbebf720d7231701a48a82) |
| 12 | borrower | Hand the veBTC position to LoanManager | [0xfaa57c8a...b6c453](https://explorer.test.mezo.org/tx/0xfaa57c8a19ba853b1c0dab02d28d926db0844bac7f572a8a890114428db6c453) |
| 13 | borrower | Borrow 15 MUSD until 2026-10-22 | [0xc6aa2ca5...a857a0](https://explorer.test.mezo.org/tx/0xc6aa2ca576bca8fcd278bcb9954cedd78a819d0878d3c0aadb1ae76491a857a0) |
| 14 | borrower | Approve MUSD for LoanManager | [0xaf1756a0...32fcbe](https://explorer.test.mezo.org/tx/0xaf1756a058f66028b978ba75e4dd32f532245b50146953fcef12cc3edd32fcbe) |
| 15 | borrower | Repay the fixed 15.0057 MUSD | [0x23ccbacc...94ad02](https://explorer.test.mezo.org/tx/0x23ccbacca524f21bd8a029453cc3b7bb374d630b9daf7a21d508d24ff794ad02) |
| 16 | borrower | Take the veBTC position back | [0x9ce83dea...cb0602](https://explorer.test.mezo.org/tx/0x9ce83dea0ed8bd3c931ddacd94fc18de1437f57445d57dd73325270017cb0602) |

Reproduce: `forge script script/DeployCore.s.sol --rpc-url mezo_testnet --broadcast --skip-simulation --slow`, then the same for `script/CoreSliceLive.s.sol`, from `packages/contracts` with a funded `.env` (see `.env.example`). Rehearse first with `script/rehearse-live.sh`.
