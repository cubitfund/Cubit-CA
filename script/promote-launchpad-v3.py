#!/usr/bin/env python3
"""Promote a launchpad v3 deployment (script/LaunchpadV3Deploy.s.sol) into the app's launchpad record.

Checks the candidate against the chain, read through a public RPC, then writes
deployments/<chain>.launchpad-v2.json for the app: the Forge v3 in force, with the Forge it replaces kept in
`previousForges` so that its children (FS, Ndog on mainnet) stay listed and tradable. The replaced record is archived as
deployments/<chain>.launchpad-v2.forge-v2.json. Nothing is sent.

    python3 script/promote-launchpad-v3.py 1            # mainnet, public RPC https://ethereum-rpc.publicnode.com
    python3 script/promote-launchpad-v3.py 11155111     # Sepolia

Checks: every broadcast transaction has a successful receipt; the Forge's runtime code hash on chain equals the one
recorded at broadcast; both hook templates on chain equal the candidate's; TokenFirstWallLib and QuoteWallLib have code;
the Forge's fee and governance vault equal the replaced Forge's; the registry names either the new Forge (registered) or
the replaced one (not yet registered: the app then shows the launchpad as registered-not-active until setForge).
"""
import argparse
import json
import subprocess
import urllib.request
from pathlib import Path

RPCS = {1: "https://ethereum-rpc.publicnode.com", 11155111: "https://ethereum-sepolia-rpc.publicnode.com"}
HERE = Path(__file__).resolve().parent.parent


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"content-type": "application/json", "user-agent": "curl/8"})
    reply = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in reply:
        raise SystemExit(f"{method}: {reply['error']}")
    return reply["result"]


def keccak(hex_data):
    return subprocess.run(["cast", "keccak", hex_data], check=True, capture_output=True, text=True).stdout.strip()


def call(url, to, signature):
    selector = subprocess.run(["cast", "sig", signature], check=True, capture_output=True, text=True).stdout.strip()
    return rpc(url, "eth_call", [{"to": to, "data": selector}, "latest"])


def word_address(word):
    return "0x" + word[-40:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("chain", type=int, nargs="?", default=1)
    parser.add_argument("--rpc", help="a public or local RPC (a fork rehearsal)")
    parser.add_argument("--broadcast", help="the broadcast run-latest.json, when FOUNDRY_BROADCAST moved it")
    args = parser.parse_args()
    chain = args.chain
    url = args.rpc or RPCS[chain]
    deployments = HERE / "deployments"
    candidate_path = deployments / f"{chain}.launchpad-v3.candidate.json"
    current_path = deployments / f"{chain}.launchpad-v2.json"
    broadcast_path = Path(args.broadcast) if args.broadcast else HERE / "broadcast" / "LaunchpadV3Deploy.s.sol" / str(chain) / "run-latest.json"
    candidate = json.loads(candidate_path.read_text())
    current = json.loads(current_path.read_text())
    broadcast = json.loads(broadcast_path.read_text())
    assert candidate["chainId"] == chain == current["chainId"], "chain mismatch"
    forge = candidate["forge"]

    # Receipts of every broadcast transaction.
    hashes, first_block = [], None
    for receipt in broadcast["receipts"]:
        onchain = rpc(url, "eth_getTransactionReceipt", [receipt["transactionHash"]])
        assert onchain and onchain["status"] == "0x1", f"transaction {receipt['transactionHash']} did not succeed"
        hashes.append(receipt["transactionHash"])
        block = int(onchain["blockNumber"], 16)
        first_block = block if first_block is None else min(first_block, block)

    code = rpc(url, "eth_getCode", [forge, "latest"])
    code_hash = keccak(code)
    assert code_hash.lower() == candidate["forgeRuntimeCodeHash"].lower(), "Forge runtime code differs from the broadcast"
    for lib in ("tokenFirstWallLib", "quoteWallLib", "bandLib"):
        assert rpc(url, "eth_getCode", [candidate[lib], "latest"]) not in ("0x", "0x0"), f"{lib} has no code"
    assert call(url, forge, "hookCreationCodeHash()").lower() == candidate["hookCreationCodeHash"].lower()
    assert call(url, forge, "tokenFirstHookCreationCodeHash()").lower() == candidate["tokenFirstHookCreationCodeHash"].lower()
    previous = current["forge"]
    assert candidate["previousForge"].lower() == previous.lower(), "the candidate replaces another Forge than the app's"
    assert int(call(url, forge, "launchFee()"), 16) == int(call(url, previous, "launchFee()"), 16), "fee changed"
    assert word_address(call(url, forge, "governanceVault()")).lower() == word_address(call(url, previous, "governanceVault()")).lower()
    registered = word_address(call(url, candidate["v2"], "forge()")).lower()
    assert registered in (forge.lower(), previous.lower()), "the registry names a third Forge"

    record = dict(candidate)
    record["deployBlock"] = first_block
    record["transactions"] = hashes
    record["previousForges"] = [{"forge": previous, "deployBlock": current["deployBlock"], "version": current.get("version", 2)}] + \
        current.get("previousForges", [])
    record["runtimeVerified"] = True
    record["broadcastVerified"] = True
    record["verification"] = (
        f"Launchpad v3 (CubitForgeV3), checked by script/promote-launchpad-v3.py against {url}: the {len(hashes)} broadcast "
        "transactions succeeded; the Forge's runtime code hash on chain equals the broadcast's; both hook templates on "
        "chain equal the candidate's; the libraries have code; fee and governance vault equal the replaced Forge's; the "
        f"registry names {'the new Forge' if registered == forge.lower() else 'the replaced Forge (setForge pending)'}. "
        "The replaced Forge's children stay listed through previousForges."
    )
    archive = deployments / f"{chain}.launchpad-v2.forge-v2.json"
    if not archive.exists():
        archive.write_text(current_path.read_text())
    current_path.write_text(json.dumps(record, indent=2) + "\n")
    print(f"promoted {forge} into {current_path.name}; replaced record archived as {archive.name}")
    print(f"registry forge(): {'NEW Forge' if registered == forge.lower() else 'still the replaced Forge (send setForge after the app is live)'}")


if __name__ == "__main__":
    main()
