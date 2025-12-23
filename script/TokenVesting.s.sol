// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TokenVesting.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title DeployTokenVesting
 * @dev Deployment script for TokenVesting contract with configuration options
 */
contract DeployTokenVesting is Script {
    // Configuration struct for deployment
    struct DeploymentConfig {
        address tokenAddress;
        address owner;
        bool createInitialSchedules;
    }

    // Vesting schedule configuration
    struct VestingConfig {
        address beneficiary;
        uint256 amount;
        uint64 startTime;
        uint64 cliffDuration;
        uint64 vestingDuration;
    }

    TokenVesting public vesting;

    // Events for tracking deployment
    event VestingDeployed(address indexed vesting, address indexed token, address indexed owner);
    event InitialScheduleCreated(address indexed beneficiary, uint256 amount);

    /**
     * @dev Main deployment function
     * @return deployed vesting contract address
     */
    function run() external returns (address) {
        DeploymentConfig memory config = getDeploymentConfig();

        vm.startBroadcast();

        vesting = deployVesting(config);

        if (config.createInitialSchedules) {
            createInitialSchedules(config);
        }

        vm.stopBroadcast();

        logDeployment(config);

        return address(vesting);
    }

    /**
     * @dev Deploy vesting contract with provided configuration
     * @param config Deployment configuration
     * @return deployed TokenVesting contract
     */
    function deployVesting(DeploymentConfig memory config) public returns (TokenVesting) {
        require(config.tokenAddress != address(0), "Invalid token address");

        TokenVesting deployed = new TokenVesting(config.tokenAddress);

        // Transfer ownership if different from deployer
        if (config.owner != address(0) && config.owner != msg.sender) {
            deployed.transferOwnership(config.owner);
        }

        emit VestingDeployed(address(deployed), config.tokenAddress, config.owner);

        return deployed;
    }

    /**
     * @dev Create initial vesting schedules based on environment
     * @param config Deployment configuration
     */
    function createInitialSchedules(DeploymentConfig memory config) public {
        VestingConfig[] memory schedules = getVestingSchedules();

        IERC20 token = IERC20(config.tokenAddress);

        // Calculate total amount needed
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < schedules.length; i++) {
            totalAmount += schedules[i].amount;
        }

        // Approve vesting contract
        token.approve(address(vesting), totalAmount);

        // Create schedules
        for (uint256 i = 0; i < schedules.length; i++) {
            vesting.createVestingSchedule(
                schedules[i].beneficiary,
                schedules[i].amount,
                schedules[i].startTime,
                schedules[i].cliffDuration,
                schedules[i].vestingDuration
            );

            emit InitialScheduleCreated(schedules[i].beneficiary, schedules[i].amount);
        }
    }

    /**
     * @dev Get deployment configuration from environment
     * @return config Deployment configuration
     */
    function getDeploymentConfig() public view returns (DeploymentConfig memory) {
        address tokenAddress = vm.envOr("TOKEN_ADDRESS", address(0));
        address owner = vm.envOr("VESTING_OWNER", msg.sender);
        bool createInitialSchedule = vm.envOr("CREATE_INITIAL_SCHEDULES", false);

        return
            DeploymentConfig({tokenAddress: tokenAddress, owner: owner, createInitialSchedules: createInitialSchedule});
    }

    /**
     * @dev Get vesting schedules configuration
     * @return Array of vesting configurations
     */
    function getVestingSchedules() public view returns (VestingConfig[] memory) {
        // Check if we're on mainnet, testnet, or local
        uint256 chainId = block.chainid;

        if (chainId == 1) {
            // Mainnet configuration
            return getMainnetSchedules();
        } else if (chainId == 11155111) {
            // Sepolia testnet
            return getTestnetSchedules();
        } else {
            // Local/Anvil - return empty array
            VestingConfig[] memory empty = new VestingConfig[](0);
            return empty;
        }
    }

    /**
     * @dev Mainnet vesting schedules
     */
    function getMainnetSchedules() internal view returns (VestingConfig[] memory) {
        VestingConfig[] memory schedules = new VestingConfig[](3);

        // Example: Founders with 4-year vesting, 1-year cliff
        schedules[0] = VestingConfig({
            beneficiary: address(0), // Set actual address
            amount: 10_000_000 * 10 ** 18,
            startTime: uint64(block.timestamp),
            cliffDuration: 365 days,
            vestingDuration: 4 * 365 days
        });

        // Team with 3-year vesting, 6-month cliff
        schedules[1] = VestingConfig({
            beneficiary: address(0), // Set actual address
            amount: 5_000_000 * 10 ** 18,
            startTime: uint64(block.timestamp),
            cliffDuration: 182 days,
            vestingDuration: 3 * 365 days
        });

        // Advisors with 2-year vesting, 3-month cliff
        schedules[2] = VestingConfig({
            beneficiary: address(0), // Set actual address
            amount: 2_000_000 * 10 ** 18,
            startTime: uint64(block.timestamp),
            cliffDuration: 90 days,
            vestingDuration: 2 * 365 days
        });

        return schedules;
    }

    /**
     * @dev Testnet vesting schedules (shorter durations for testing)
     */
    function getTestnetSchedules() internal view returns (VestingConfig[] memory) {
        VestingConfig[] memory schedules = new VestingConfig[](2);

        // Short vesting for testing: 30 days total, 7 days cliff
        schedules[0] = VestingConfig({
            beneficiary: address(0), // Set actual address
            amount: 1000 * 10 ** 18,
            startTime: uint64(block.timestamp),
            cliffDuration: 7 days,
            vestingDuration: 30 days
        });

        schedules[1] = VestingConfig({
            beneficiary: address(0), // Set actual address
            amount: 500 * 10 ** 18,
            startTime: uint64(block.timestamp),
            cliffDuration: 3 days,
            vestingDuration: 15 days
        });

        return schedules;
    }

    /**
     * @dev Log deployment information
     */
    function logDeployment(DeploymentConfig memory config) internal view {
        console.log("========================================");
        console.log("TokenVesting Deployment");
        console.log("========================================");
        console.log("Vesting Contract:", address(vesting));
        console.log("Token Address:", config.tokenAddress);
        console.log("Owner:", vesting.owner());
        console.log("Chain ID:", block.chainid);
        console.log("Block Number:", block.number);
        console.log("Deployer:", msg.sender);
        console.log("========================================");

        if (config.createInitialSchedules) {
            console.log("Initial Schedules Created:", vesting.getBeneficiaryCount());
            console.log("Total Vesting Amount:", vesting.totalVestingAmount());
        }

        console.log("========================================");
    }
}

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

/**
 * @title MockERC20
 * @dev Simple mock ERC20 for testing
 */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
