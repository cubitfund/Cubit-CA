// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ITestToken {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external; // no return value: USDT's mock returns none
}

interface IWETH9 {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external payable returns (address pool);
    function mint(MintParams calldata params)
        external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @notice Uniswap v3 pools for the test quotes on Sepolia, so the app can pay a launchpad v2 pair with ETH the way it
///         does on mainnet (WETH → USDC → stock, WETH → USDC → USDT or WBTC): WETH/USDC at 0.05 %, then USDC against
///         each other test quote. Every position is full range, owned by the signer. Only the WETH side costs real
///         Sepolia ETH (`WETH_IN`, default 0.05 ETH); the test quotes are minted. Prices are illustrative.
///         Sepolia only. Writes deployments/routes/<chainId>.json.
///           forge script script/EthRoutePools.s.sol --rpc-url <public sepolia rpc> --broadcast --account … --password-file …
contract EthRoutePools is Script {
    address constant NPM = 0x1238536071E1c677A632429e3655c799b22cDA52; // Sepolia NonfungiblePositionManager
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // its WETH9, the Universal Router's too

    string json;

    function run() external {
        // Sepolia's NonfungiblePositionManager and WETH are hard-coded: Sepolia only (or a fork of it).
        require(block.chainid == 11155111, "test pools are for Sepolia only");
        string memory table = vm.readFile("deployments/quotes/11155111.json");
        address usdc = vm.parseJsonAddress(table, ".quotes[1].address");
        require(keccak256(bytes(vm.parseJsonString(table, ".quotes[1].symbol"))) == keccak256("USDC"), "row 1 must be USDC");
        string[7] memory expected = ["USDT", "WBTC", "NVDAon", "SPCXon", "TSLAon", "AAPLon", "GOOGLon"];
        for (uint256 i; i < 7; i++) {
            string memory at = string.concat(".quotes[", vm.toString(i + 2), "].symbol");
            require(keccak256(bytes(vm.parseJsonString(table, at))) == keccak256(bytes(expected[i])), "unexpected row order");
        }
        uint256 wethIn = vm.envOr("WETH_IN", uint256(0.05 ether));
        uint256 ethUsd = 2_600;
        // Test quotes after USDC, with their price in USDC and pool fee. Order of deployments/quotes/11155111.json.
        uint256[7] memory usdPrice = [uint256(1), 100_000, 180, 200, 400, 250, 250];
        uint24[7] memory fees = [uint24(100), 3_000, 3_000, 3_000, 3_000, 3_000, 3_000];
        uint256 usdcPerPool = 20_000e6;

        vm.startBroadcast();
        address me = msg.sender;
        json = string.concat("{\n  \"chainId\": ", vm.toString(block.chainid), ",\n  \"pools\": [");

        IWETH9(WETH).deposit{value: wethIn}();
        IWETH9(WETH).approve(NPM, wethIn);
        uint256 usdcTotal = wethIn * ethUsd / 1e12 + usdcPerPool * 7;
        ITestToken(usdc).mint(me, usdcTotal);
        ITestToken(usdc).approve(NPM, usdcTotal);
        _pool(WETH, wethIn, usdc, wethIn * ethUsd / 1e12, 500, me, true);

        for (uint256 i; i < 7; i++) {
            string memory path = string.concat(".quotes[", vm.toString(i + 2), "]");
            address token = vm.parseJsonAddress(table, string.concat(path, ".address"));
            uint256 decimals = vm.parseJsonUint(table, string.concat(path, ".decimals"));
            uint256 amount = usdcPerPool * 10 ** decimals / 1e6 / usdPrice[i];
            ITestToken(token).mint(me, amount);
            ITestToken(token).approve(NPM, amount);
            _pool(usdc, usdcPerPool, token, amount, fees[i], me, false);
        }
        vm.stopBroadcast();

        json = string.concat(json, "\n  ]\n}\n");
        vm.writeFile(string.concat("deployments/routes/", vm.toString(block.chainid), ".json"), json);
        console2.log("pools written to deployments/routes/<chainId>.json");
    }

    function _pool(address a, uint256 amountA, address b, uint256 amountB, uint24 fee, address me, bool first) internal {
        (address t0, uint256 a0, address t1, uint256 a1) = a < b ? (a, amountA, b, amountB) : (b, amountB, a, amountA);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(FullMath.mulDiv(a1, 1 << 192, a0)));
        address pool = INonfungiblePositionManager(NPM).createAndInitializePoolIfNecessary(t0, t1, fee, sqrtPriceX96);
        int24 spacing = fee == 100 ? int24(1) : fee == 500 ? int24(10) : fee == 3_000 ? int24(60) : int24(200);
        int24 top = 887_272 / spacing * spacing;
        (uint256 tokenId, uint128 liquidity,,) = INonfungiblePositionManager(NPM).mint(
            INonfungiblePositionManager.MintParams(t0, t1, fee, -top, top, a0, a1, 0, 0, me, block.timestamp + 1 hours)
        );
        console2.log("pool", pool, fee);
        console2.log("  position", tokenId, liquidity);
        json = string.concat(
            json, first ? "" : ",", "\n    { \"token0\": \"", vm.toString(t0), "\", \"token1\": \"", vm.toString(t1),
            "\", \"fee\": ", vm.toString(uint256(fee)), ", \"pool\": \"", vm.toString(pool), "\", \"positionId\": ",
            vm.toString(tokenId), " }"
        );
    }
}
