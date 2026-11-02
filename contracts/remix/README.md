# Remix-ready sources

Self-contained (flattened) copies of the two contracts in `../src`, with OpenZeppelin 5.6.1 inlined, for
pasting into Remix. They are generated, not hand-edited:

```
for c in FluxoraToken FluxoraPayments; do
  forge flatten contracts/src/$c.sol -o contracts/remix/$c.flat.sol
done
```

Compile with Solidity `0.8.28`, EVM `cancun`, optimizer on, 200 runs. Those settings give bytecode identical
to the Foundry build used by the tests. Regenerate these files after every change to `../src`.

Step-by-step deployment: `docs/REMIX_DEPLOYMENT.md`.
