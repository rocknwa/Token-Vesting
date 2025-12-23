// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/TokenVesting.sol";
import "../src/Token.sol";

/**
 * @title DeployMockSetup
 * @dev Deployment script that includes mock token for testing
 */
contract DeployMockSetup is Script {
    TokenVesting public vesting;
    MockERC20 public token;

    function run() external returns (address vestingAddress, address tokenAddress) {
        vm.startBroadcast();

        // Deploy mock token
        token = new MockERC20();

        // Deploy vesting
        vesting = new TokenVesting(address(token));

        vm.stopBroadcast();

        console.log("Mock Token:", address(token));
        console.log("Vesting Contract:", address(vesting));

        return (address(vesting), address(token));
    }
}
