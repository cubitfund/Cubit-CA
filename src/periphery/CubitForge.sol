// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CubitHook} from "../CubitHook.sol";
import {CubitToken} from "../CubitToken.sol";
import {ICubitV2, ICubitGovernanceVault} from "../interfaces/ICubitV2.sol";

/// @dev Immutable ERC20 name/symbol per child; exactly the core's fixed supply and
/// one-shot burn authority. No relationship with the parent token or floor permissions.
contract CubitForgeToken is CubitToken {
    string private _childName;
    string private _childSymbol;
    constructor(string memory name_, string memory symbol_) { _childName = name_; _childSymbol = symbol_; }
    function name() public view override returns (string memory) { return _childName; }
    function symbol() public view override returns (string memory) { return _childSymbol; }
}

/// @notice The public launchpad: anyone launches a token by paying the launch fee. Every child runs the frozen CubitHook
/// creation code with its own token, claims and pool ID, under the same imposed parameters: its whole fixed supply in
/// its band at the parent's launch value, and the same taxes. There is no delegatecall, proxy or shared permission. The
/// supplied creation code is checked against a hash fixed at construction; supplying it as calldata keeps this factory
/// below EIP-170's runtime bytecode size limit. A replacement Forge registered later (a launchpad v2) can set other
/// parameters; children already launched keep theirs.
/// @dev Both CREATE2 salts are bound to the launcher as `keccak256(abi.encode(msg.sender, salt))`. The child token's
///      address therefore depends only on the launcher, its token salt, the name and the symbol, never on how many
///      launches came first: a hook salt mined in advance stays valid whoever launches in the same block, and nobody can
///      take a pending launch's addresses by copying its salts.
contract CubitForge is ReentrancyGuard {
    CubitHook public immutable hook;
    bytes32 public immutable hookCreationCodeHash;
    uint256 public immutable launchFee;
    /// @notice Launchpad governance vault. Every launch fee is locked here, in ETH. A child has no vault of
    ///         its own: the tokens its walls absorb are delivered here too, where the child hook finds this
    ///         address through its token's deployer.
    address public immutable governanceVault;
    uint256 public launches;
    event ChildLaunched(address indexed token, address indexed hook, address indexed launcher, address team, uint256 fee);

    constructor(CubitHook hook_, uint256 launchFee_, address governanceVault_) {
        require(launchFee_ != 0, "zero fee");
        require(governanceVault_.code.length != 0, "governance vault missing");
        hook = hook_;
        launchFee = launchFee_;
        governanceVault = governanceVault_;
        hookCreationCodeHash = keccak256(type(CubitHook).creationCode);
    }

    /// @notice Launch a child token; `team` receives the child's taxes. The child token is created with the salt
    ///         `keccak256(abi.encode(msg.sender, tokenSalt))` and the child hook with `keccak256(abi.encode(msg.sender,
    ///         hookSalt))`; `hookSalt` must give the hook address the six hook flags.
    function launch(
        string calldata name_,
        string calldata symbol_,
        address team,
        bytes32 tokenSalt,
        bytes32 hookSalt,
        bytes calldata creationCode
    ) external payable nonReentrant returns (address childToken, address childHook) {
        address registry = hook.v2();
        require(registry != address(0) && ICubitV2(registry).forge() == address(this) &&
            ICubitV2(registry).enabledFeatures() & 8 != 0, "Forge inactive");
        require(msg.value == launchFee, "wrong launch fee");
        require(bytes(name_).length > 0 && bytes(name_).length <= 64 &&
            bytes(symbol_).length > 0 && bytes(symbol_).length <= 12, "invalid name");
        require(team != address(0) && team != address(hook), "invalid team");
        require(keccak256(creationCode) == hookCreationCodeHash, "template mismatch");
        CubitForgeToken token = new CubitForgeToken{salt: keccak256(abi.encode(msg.sender, tokenSalt))}(name_, symbol_);
        // The prefix hash is frozen and the constructor suffix is exactly four static
        // ABI words. This is code concatenation, not a hash of ambiguous user strings.
        bytes memory initCode = bytes.concat(creationCode, abi.encode(hook.poolManager(), token, team, hook.LAUNCH_ETH()));
        bytes32 salt = keccak256(abi.encode(msg.sender, hookSalt));
        assembly ("memory-safe") { childHook := create2(0, add(initCode, 32), mload(initCode), salt) }
        require(childHook != address(0), "child deployment failed");
        CubitHook child = CubitHook(payable(childHook));
        token.setHook(childHook);
        // A child has no vault reserve: its whole supply goes into its band.
        require(token.transfer(childHook, token.TOTAL_SUPPLY()), "child funding failed");
        child.poolManager().initialize(child.poolKey(), child.INITIAL_SQRT_PRICE());
        ICubitGovernanceVault(governanceVault).depositEth{value: msg.value}();
        launches++;
        childToken = address(token);
        emit ChildLaunched(childToken, childHook, msg.sender, team, msg.value);
    }
}
