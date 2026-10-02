// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {CubitHook} from "../CubitHook.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

interface ICubitModule {
    function hook() external view returns (address);
    function token() external view returns (address);
    function poolManager() external view returns (address);
    function poolId() external view returns (bytes32);
    function totalStaked() external view returns (uint256);
    function governanceVault() external view returns (address);
}

/// @notice Stable release registry with replaceable peripheral contracts.
/// The team can replace compatible Vault, Router, Lens and Forge deployments at any time. Replacing the Vault, the Lens
/// or the Forge disables its feature until the team activates it again; the Router has no feature. Nothing ever
/// activates by itself, and no activation waits for a date. The launchpad (Forge) is not needed at launch: the registry
/// can start without one, and the team registers it later. Core pool identities remain anchored here. Old vaults
/// retain their users' principal/rewards and remain available for withdrawals and claims.
contract CubitV2 {
    uint8 public constant VAULT = 1;
    /// @dev Bit 2 belonged to the referral feature, removed on 15 September 2026: it is never a valid feature.
    uint8 public constant MOMENTUM = 4;
    uint8 public constant FORGE = 8;

    CubitHook public immutable hook;
    address public immutable authority;
    address public vault;
    address public router;
    address public forge;
    address public lens;
    uint256 public moduleRevision;
    address[] public vaults;
    mapping(address => bool) public isVault;
    uint8 public enabledFeatures;

    event FeatureActivated(uint8 indexed feature, uint256 timestamp);
    event ModuleUpdated(bytes32 indexed module, address indexed previous, address indexed current, uint256 revision);
    event FeatureDeactivated(uint8 indexed feature);
    error NotAuthority();
    error InvalidFeature();
    error NotReady();
    error AlreadyActive();
    error InvalidModule();

    /// @param forge_ The launchpad module, or address zero to launch without one.
    constructor(CubitHook hook_, address vault_, address router_, address forge_, address lens_) {
        hook = hook_;
        authority = hook_.TEAM_ADDRESS();
        _checkVault(vault_);
        _checkPool(router_);
        if (forge_ != address(0)) _checkForge(forge_);
        _checkLens(lens_);
        vault = vault_;
        router = router_;
        forge = forge_;
        lens = lens_;
        isVault[vault_] = true;
        vaults.push(vault_);
    }

    modifier onlyAuthority() {
        if (msg.sender != authority) revert NotAuthority();
        _;
    }

    function vaultCount() external view returns (uint256) { return vaults.length; }

    /// @notice Retire the previous vault without moving anyone's tokens or rewards.
    /// The old vault rejects further deposits through its current-registry check.
    function setVault(address next) external onlyAuthority {
        if (isVault[next]) revert InvalidModule();
        _checkVault(next);
        address previous = vault;
        vault = next;
        isVault[next] = true;
        vaults.push(next);
        _changed("VAULT", previous, next, VAULT);
    }

    /// @notice Replace the router the dapp trades through. It has no feature to disable.
    function setRouter(address next) external onlyAuthority {
        if (next == router) revert InvalidModule();
        _checkPool(next);
        address previous = router;
        router = next;
        _changed("ROUTER", previous, next, 0);
    }

    /// @notice Register the launchpad module, or replace it with another one (a launchpad v2). Children already launched
    ///         keep running on their own pools; new launches go through the registered module once it is activated.
    function setForge(address next) external onlyAuthority {
        if (next == forge) revert InvalidModule();
        _checkForge(next);
        address previous = forge;
        forge = next;
        _changed("FORGE", previous, next, FORGE);
    }

    function setLens(address next) external onlyAuthority {
        if (next == lens) revert InvalidModule();
        _checkLens(next);
        address previous = lens;
        lens = next;
        _changed("LENS", previous, next, MOMENTUM);
    }

    function _changed(bytes32 name, address previous, address next, uint8 feature) internal {
        if (enabledFeatures & feature != 0) {
            enabledFeatures &= ~feature;
            emit FeatureDeactivated(feature);
        }
        emit ModuleUpdated(name, previous, next, ++moduleRevision);
    }

    function _checkHook(address candidate) internal view {
        if (candidate.code.length == 0 || ICubitModule(candidate).hook() != address(hook)) revert InvalidModule();
    }

    function _checkPool(address candidate) internal view {
        _checkHook(candidate);
        if (ICubitModule(candidate).poolManager() != address(hook.poolManager()) ||
            ICubitModule(candidate).poolId() != PoolId.unwrap(hook.poolId())) revert InvalidModule();
    }

    function _checkLens(address candidate) internal view {
        _checkPool(candidate);
        if (ICubitModule(candidate).token() != address(hook.token())) revert InvalidModule();
    }

    function _checkVault(address candidate) internal view {
        _checkHook(candidate);
        if (ICubitModule(candidate).token() != address(hook.token()) ||
            ICubitModule(candidate).totalStaked() != 0) revert InvalidModule();
    }

    /// @dev A launchpad module serves this hook and names a governance vault with code: a child built on the CUBIT hook
    ///      template delivers its absorbed tokens there, found through its token's deployer.
    function _checkForge(address candidate) internal view {
        _checkHook(candidate);
        if (ICubitModule(candidate).governanceVault().code.length == 0) revert InvalidModule();
    }

    /// @notice Turn a feature on. Only the team, at any time once the pool is live; nothing activates by itself. The
    ///         Forge feature needs a registered launchpad module.
    function activate(uint8 feature) external onlyAuthority {
        if (feature != VAULT && feature != MOMENTUM && feature != FORGE) revert InvalidFeature();
        if (!hook.initialized() || hook.v2() != address(this)) revert NotReady();
        if (feature == FORGE && forge == address(0)) revert NotReady();
        if (enabledFeatures & feature != 0) revert AlreadyActive();
        enabledFeatures |= feature;
        emit FeatureActivated(feature, block.timestamp);
    }

}
