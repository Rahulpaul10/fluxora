# FLUXORA Payments - standalone, one file

`FluxoraPaymentsStandalone.sol` is a self-contained copy (OpenZeppelin 5.6.1 inlined) of
`../src/FluxoraPaymentsStandalone.sol`, ready to paste into Remix.

- Compiler 0.8.28, EVM `cancun`, optimizer on with 200 runs
- Constructor `(uint48 adminTransferDelay, address[] initialTokens)`; the deployer becomes admin and pauser
- ABI: `FluxoraPaymentsStandalone.abi.json`
- Instructions: `../../docs/PAYMENTS_REMIX_DEPLOYMENT.md`

Regenerate after any change to `../src/FluxoraPaymentsStandalone.sol`: `forge flatten`, re-add the header banner,
then re-run the tests. Do not hand-edit the single file.
