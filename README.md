# CUBIT — contracts

Solidity sources of CUBIT (Foundry). CUBIT is an ERC-20 token whose only market maker is a Uniswap v4 hook. The hook
holds one liquidity band with the whole tradable supply, and every sale funds a "wall": a narrow buy position placed
under the price, which never moves. A staking vault pays rewards in CUBIT, and a public launchpad lets anyone launch a
token that runs the same mechanism.

- App: https://cubit.fund
- Documentation: https://gitbook.cubit.fund

## Layout

| Path | Content |
|---|---|
| `src/CubitHook.sol` | The hook: taxes, the band, the walls; no owner, no pause, no upgrade |
| `src/libraries/` | `BandLib` (band and wall geometry) and `WallLib` (the wall book) |
| `src/periphery/` | The registry (`CubitV2`) and its modules: vault, router, launch, launchpad (`CubitForge`), governance vault |
| `src/CubitLens.sol` | Read-only views for the app |
| `src/quote/`, `src/periphery/CubitForgeV2.sol`, `src/periphery/CubitForgeV3.sol` | The launchpad on mainnet: children paired with ETH, USDC, USDT, WBTC or tokenized stocks. `CubitForgeV3` (in force) puts every ERC-20 pair's token first (`CubitTokenFirstHook`); tokens launched by the earlier Forges keep trading |
| `script/` | Deployment and rehearsal scripts |
| `test/redesign/` | Unit, fuzz, invariant and fork tests |
| `audit/` | Medusa and Halmos harnesses |
| `deployments/` | Mainnet (chain 1) and Sepolia (chain 11155111) manifests: addresses, transactions, runtime code hashes |

## Economics

Taxes: 3% on buys to the team; 15% on sales, of which 12% funds a wall at 40% of the current price plus 60% of the
launch price (1% under the price at or below launch) and 3% goes to the team. Walls on the same tick merge and never
move; a wall the price fully crosses is emptied and its CUBIT go to the vault's reward reserve.

## Build and test

```bash
git submodule update --init --recursive
# The current test suites live in test/redesign. via_ir compiles slowly and needs about 4 GB of RAM.
FOUNDRY_TEST=test/redesign forge test
```

Fork suites read `MAINNET_RPC_URL` and `FORK_BLOCK` from the environment; copy `.env.example` to `.env`.

## Security

The code has been tested with Foundry (unit, fuzz and invariant tests, mainnet forks) and analysed with Slither,
Aderyn, Mythril, Medusa and Halmos. These are automated and AI-assisted reviews, not an independent human audit.
