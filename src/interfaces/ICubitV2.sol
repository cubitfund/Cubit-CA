// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

interface ICubitV2 {
    function hook() external view returns (address);
    function vault() external view returns (address);
    function router() external view returns (address);
    function forge() external view returns (address);
    function lens() external view returns (address);
    function enabledFeatures() external view returns (uint8);
    function vaultCount() external view returns (uint256);
    function vaults(uint256 index) external view returns (address);
}

interface ICubitVault {
    function hook() external view returns (address);
    function totalStaked() external view returns (uint256);
    function rewardReserve() external view returns (uint256);
    function fundRewardReserve(uint256 amount) external;
}

/// @notice The Forge that deploys a child token names the launchpad governance vault its hook delivers to.
interface ICubitForgeSink {
    function governanceVault() external view returns (address);
}

interface ICubitGovernanceVault {
    function lockUntracked(address token) external;
    function depositEth() external payable;
}
