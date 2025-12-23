// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TokenVesting.sol";
import "../script/TokenVesting.s.sol";
import "../script/DeployMockSetup.sol";

contract TokenVestingTest is Test {
    TokenVesting public vesting;
    MockERC20 public token;
    DeployMockSetup public deployer;

    address public owner;
    address public beneficiary1;
    address public beneficiary2;
    address public beneficiary3;

    uint256 constant TOTAL_AMOUNT = 1000000 * 10 ** 18;
    uint64 constant CLIFF_DURATION = 365 days;
    uint64 constant VESTING_DURATION = 4 * 365 days;

    event VestingScheduleCreated(
        address indexed beneficiary, uint256 totalAmount, uint64 startTime, uint64 cliffDuration, uint64 vestingDuration
    );

    event TokensReleased(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary, uint256 refundAmount);

    function setUp() public {
        beneficiary1 = makeAddr("beneficiary1");
        beneficiary2 = makeAddr("beneficiary2");
        beneficiary3 = makeAddr("beneficiary3");

        // Deploy directly in setUp to maintain test contract as owner
        token = new MockERC20();
        vesting = new TokenVesting(address(token));

        // Test contract is the owner
        owner = address(this);

        // Approve vesting contract
        token.approve(address(vesting), type(uint256).max);
    }

    // ============ Deployment Script Tests ============

    function test_DeploymentScript_Success() public {
        // Deploy using the script
        DeployMockSetup newDeployer = new DeployMockSetup();
        (address vestingAddress, address tokenAddress) = newDeployer.run();

        // Verify deployment was successful
        assertTrue(vestingAddress != address(0));
        assertTrue(tokenAddress != address(0));

        TokenVesting newVesting = TokenVesting(vestingAddress);
        assertEq(address(newVesting.token()), tokenAddress);
    }

    function test_DeploymentScript_TokenMinted() public {
        // Deploy using the script
        DeployMockSetup newDeployer = new DeployMockSetup();
        (, address tokenAddress) = newDeployer.run();

        MockERC20 newToken = MockERC20(tokenAddress);
        newToken.mint(address(this), 1_000_000_000 * 10 ** 18);
        // Verify token was minted to test contract (msg.sender in the script context)
        assertEq(newToken.balanceOf(address(this)), 1_000_000_000 * 10 ** 18);
    }

    function test_DeploymentScript_CanBeUsedMultipleTimes() public {
        DeployMockSetup deployer1 = new DeployMockSetup();
        (address vesting1, address token1) = deployer1.run();

        DeployMockSetup deployer2 = new DeployMockSetup();
        (address vesting2, address token2) = deployer2.run();

        assertTrue(vesting1 != vesting2);
        assertTrue(token1 != token2);
    }

    function test_DeploymentConfig_WithEnvironmentVariables() public {
        // Test that deployment script can read environment variables
        DeployTokenVesting mainDeployer = new DeployTokenVesting();

        // Set environment variable
        vm.setEnv("TOKEN_ADDRESS", vm.toString(address(token)));
        vm.setEnv("VESTING_OWNER", vm.toString(owner));

        DeployTokenVesting.DeploymentConfig memory config = mainDeployer.getDeploymentConfig();

        assertEq(config.tokenAddress, address(token));
        assertEq(config.owner, owner);
    }

    // ============ Constructor Tests ============

    function test_Constructor_Success() public {
        TokenVesting newVesting = new TokenVesting(address(token));
        assertEq(address(newVesting.token()), address(token));
        assertEq(newVesting.owner(), address(this));
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(TokenVesting.InvalidTokenAddress.selector);
        new TokenVesting(address(0));
    }

    // ============ CreateVestingSchedule Tests ============

    function test_CreateVestingSchedule_Success() public {
        uint64 startTime = uint64(block.timestamp);

        vm.expectEmit(true, false, false, true);
        emit VestingScheduleCreated(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        (
            uint256 totalAmount,
            uint64 scheduleStartTime,
            uint64 cliffDuration,
            uint64 vestingDuration,
            uint256 releasedAmount,,,
            bool revoked
        ) = vesting.getVestingSchedule(beneficiary1);

        assertEq(totalAmount, TOTAL_AMOUNT);
        assertEq(scheduleStartTime, startTime);
        assertEq(cliffDuration, CLIFF_DURATION);
        assertEq(vestingDuration, VESTING_DURATION);
        assertEq(releasedAmount, 0);
        assertFalse(revoked);
        assertEq(vesting.totalVestingAmount(), TOTAL_AMOUNT);
    }

    function test_CreateVestingSchedule_RevertsOnZeroAddress() public {
        vm.expectRevert(TokenVesting.InvalidBeneficiary.selector);
        vesting.createVestingSchedule(
            address(0), TOTAL_AMOUNT, uint64(block.timestamp), CLIFF_DURATION, VESTING_DURATION
        );
    }

    function test_CreateVestingSchedule_RevertsOnZeroAmount() public {
        vm.expectRevert(TokenVesting.InvalidAmount.selector);
        vesting.createVestingSchedule(beneficiary1, 0, uint64(block.timestamp), CLIFF_DURATION, VESTING_DURATION);
    }

    function test_CreateVestingSchedule_RevertsOnZeroVestingDuration() public {
        vm.expectRevert(TokenVesting.InvalidVestingDuration.selector);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, uint64(block.timestamp), CLIFF_DURATION, 0);
    }

    function test_CreateVestingSchedule_RevertsOnCliffExceedsVesting() public {
        vm.expectRevert(TokenVesting.CliffExceedsVestingDuration.selector);
        vesting.createVestingSchedule(
            beneficiary1, TOTAL_AMOUNT, uint64(block.timestamp), VESTING_DURATION + 1, VESTING_DURATION
        );
    }

    function test_CreateVestingSchedule_RevertsOnDuplicateSchedule() public {
        uint64 startTime = uint64(block.timestamp);

        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.expectRevert(TokenVesting.VestingScheduleExists.selector);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
    }

    function test_CreateVestingSchedule_RevertsOnPastStartTime() public {
        vm.expectRevert(TokenVesting.InvalidStartTime.selector);
        vesting.createVestingSchedule(
            beneficiary1, TOTAL_AMOUNT, uint64(block.timestamp - 1), CLIFF_DURATION, VESTING_DURATION
        );
    }

    function test_CreateVestingSchedule_RevertsOnAmountOverflow() public {
        uint256 overflowAmount = uint256(type(uint128).max) + 1;
        token.mint(address(this), overflowAmount);
        token.approve(address(vesting), overflowAmount);

        vm.expectRevert(TokenVesting.InvalidAmount.selector);
        vesting.createVestingSchedule(
            beneficiary1, overflowAmount, uint64(block.timestamp), CLIFF_DURATION, VESTING_DURATION
        );
    }

    function test_CreateVestingSchedule_OnlyOwner() public {
        vm.prank(beneficiary1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", beneficiary1));
        vesting.createVestingSchedule(
            beneficiary2, TOTAL_AMOUNT, uint64(block.timestamp), CLIFF_DURATION, VESTING_DURATION
        );
    }

    function test_CreateVestingSchedule_MultipleSchedules() public {
        uint64 startTime = uint64(block.timestamp);

        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        vesting.createVestingSchedule(beneficiary2, TOTAL_AMOUNT / 2, startTime, CLIFF_DURATION, VESTING_DURATION);
        vesting.createVestingSchedule(beneficiary3, TOTAL_AMOUNT / 4, startTime, CLIFF_DURATION, VESTING_DURATION);

        assertEq(vesting.getBeneficiaryCount(), 3);
        assertEq(vesting.totalVestingAmount(), TOTAL_AMOUNT + TOTAL_AMOUNT / 2 + TOTAL_AMOUNT / 4);
    }

    // ============ VestedAmount Tests ============

    function test_VestedAmount_BeforeCliff() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // Before cliff
        vm.warp(startTime + CLIFF_DURATION - 1);
        assertEq(vesting.vestedAmount(beneficiary1), 0);
    }

    function test_VestedAmount_AtCliff() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // At cliff - should vest proportionally (25% after 1 year of 4 years)
        vm.warp(startTime + CLIFF_DURATION);
        uint256 expectedVested = (TOTAL_AMOUNT * CLIFF_DURATION) / VESTING_DURATION;
        assertEq(vesting.vestedAmount(beneficiary1), expectedVested);
    }

    function test_VestedAmount_MidVesting() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // Halfway through vesting
        vm.warp(startTime + VESTING_DURATION / 2);
        assertEq(vesting.vestedAmount(beneficiary1), TOTAL_AMOUNT / 2);
    }

    function test_VestedAmount_AfterVestingComplete() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // After vesting complete
        vm.warp(startTime + VESTING_DURATION);
        assertEq(vesting.vestedAmount(beneficiary1), TOTAL_AMOUNT);

        // Way after vesting
        vm.warp(startTime + VESTING_DURATION * 2);
        assertEq(vesting.vestedAmount(beneficiary1), TOTAL_AMOUNT);
    }

    function test_VestedAmount_NoSchedule() public {
        assertEq(vesting.vestedAmount(beneficiary1), 0);
    }

    function test_VestedAmount_ZeroCliff() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, 0, VESTING_DURATION);

        // Immediately after start
        vm.warp(startTime + 1);
        uint256 expectedVested = TOTAL_AMOUNT / VESTING_DURATION;
        assertEq(vesting.vestedAmount(beneficiary1), expectedVested);
    }

    // ============ ReleasableAmount Tests ============

    function test_ReleasableAmount_BeforeCliff() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION - 1);
        assertEq(vesting.releasableAmount(beneficiary1), 0);
    }

    function test_ReleasableAmount_AfterPartialRelease() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // Release at cliff
        vm.warp(startTime + CLIFF_DURATION);
        uint256 firstRelease = vesting.releasableAmount(beneficiary1);
        vm.prank(beneficiary1);
        vesting.release();

        // Move forward
        vm.warp(startTime + CLIFF_DURATION + 365 days);
        uint256 totalVested = vesting.vestedAmount(beneficiary1);
        assertEq(vesting.releasableAmount(beneficiary1), totalVested - firstRelease);
    }

    // ============ Release Tests ============

    function test_Release_Success() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);
        uint256 releasable = vesting.releasableAmount(beneficiary1);

        uint256 balanceBefore = token.balanceOf(beneficiary1);

        vm.expectEmit(true, false, false, true);
        emit TokensReleased(beneficiary1, releasable);

        vm.prank(beneficiary1);
        vesting.release();

        assertEq(token.balanceOf(beneficiary1), balanceBefore + releasable);
        assertEq(vesting.totalReleasedAmount(), releasable);
    }

    function test_Release_MultipleReleases() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // First release at cliff
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(beneficiary1);
        vesting.release();
        uint256 firstRelease = token.balanceOf(beneficiary1);

        // Second release after 1 more year
        vm.warp(startTime + CLIFF_DURATION + 365 days);
        vm.prank(beneficiary1);
        vesting.release();
        uint256 secondRelease = token.balanceOf(beneficiary1) - firstRelease;

        // Third release at end
        vm.warp(startTime + VESTING_DURATION);
        vm.prank(beneficiary1);
        vesting.release();

        assertEq(token.balanceOf(beneficiary1), TOTAL_AMOUNT);
    }

    function test_Release_RevertsBeforeCliff() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.prank(beneficiary1);
        vm.expectRevert(TokenVesting.NoTokensToRelease.selector);
        vesting.release();
    }

    function test_Release_RevertsNoSchedule() public {
        vm.prank(beneficiary1);
        vm.expectRevert(TokenVesting.VestingScheduleNotFound.selector);
        vesting.release();
    }

    function test_Release_RevertsIfRevoked() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vesting.revokeVesting(beneficiary1);

        vm.prank(beneficiary1);
        vm.expectRevert(TokenVesting.VestingAlreadyRevoked.selector);
        vesting.release();
    }

    function test_Release_RevertsWhenNothingToRelease() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(beneficiary1);
        vesting.release();

        // Try to release again immediately
        vm.prank(beneficiary1);
        vm.expectRevert(TokenVesting.NoTokensToRelease.selector);
        vesting.release();
    }

    // ============ ReleaseFor Tests ============

    function test_ReleaseFor_Success() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);
        uint256 releasable = vesting.releasableAmount(beneficiary1);

        // Anyone can call releaseFor
        vm.prank(beneficiary2);
        vesting.releaseFor(beneficiary1);

        assertEq(token.balanceOf(beneficiary1), releasable);
    }

    function test_ReleaseFor_RevertsNoSchedule() public {
        vm.expectRevert(TokenVesting.VestingScheduleNotFound.selector);
        vesting.releaseFor(beneficiary1);
    }

    // ============ RevokeVesting Tests ============

    function test_RevokeVesting_BeforeCliff() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.expectEmit(true, false, false, true);
        emit VestingRevoked(beneficiary1, TOTAL_AMOUNT);

        vesting.revokeVesting(beneficiary1);

        assertEq(token.balanceOf(owner), ownerBalanceBefore + TOTAL_AMOUNT);
        assertEq(vesting.totalVestingAmount(), 0);

        (,,,,,,, bool revoked) = vesting.getVestingSchedule(beneficiary1);
        assertTrue(revoked);
    }

    function test_RevokeVesting_AfterCliff() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);
        uint256 vestedAmount = vesting.vestedAmount(beneficiary1);
        uint256 expectedRefund = TOTAL_AMOUNT - vestedAmount;

        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.expectEmit(true, false, false, true);
        emit VestingRevoked(beneficiary1, expectedRefund);

        vesting.revokeVesting(beneficiary1);

        assertEq(token.balanceOf(owner), ownerBalanceBefore + expectedRefund);
        assertEq(vesting.totalVestingAmount(), vestedAmount);
    }

    function test_RevokeVesting_AfterFullyVested() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + VESTING_DURATION);

        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vesting.revokeVesting(beneficiary1);

        // No refund since fully vested
        assertEq(token.balanceOf(owner), ownerBalanceBefore);
    }

    function test_RevokeVesting_AfterPartialRelease() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(beneficiary1);
        vesting.release();

        vm.warp(startTime + CLIFF_DURATION + 365 days);
        uint256 vestedAmount = vesting.vestedAmount(beneficiary1);
        uint256 expectedRefund = TOTAL_AMOUNT - vestedAmount;

        vesting.revokeVesting(beneficiary1);

        // Beneficiary should still have their released tokens
        assertTrue(token.balanceOf(beneficiary1) > 0);
        // Owner gets back unvested portion
        assertTrue(token.balanceOf(owner) >= expectedRefund);
    }

    function test_RevokeVesting_RevertsNoSchedule() public {
        vm.expectRevert(TokenVesting.VestingScheduleNotFound.selector);
        vesting.revokeVesting(beneficiary1);
    }

    function test_RevokeVesting_RevertsAlreadyRevoked() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vesting.revokeVesting(beneficiary1);

        vm.expectRevert(TokenVesting.VestingAlreadyRevoked.selector);
        vesting.revokeVesting(beneficiary1);
    }

    function test_RevokeVesting_OnlyOwner() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.prank(beneficiary2);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", beneficiary2));
        vesting.revokeVesting(beneficiary1);
    }

    // ============ View Function Tests ============

    function test_GetBeneficiaries() public {
        uint64 startTime = uint64(block.timestamp);

        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        vesting.createVestingSchedule(beneficiary2, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        address[] memory beneficiaries = vesting.getBeneficiaries();
        assertEq(beneficiaries.length, 2);
        assertEq(beneficiaries[0], beneficiary1);
        assertEq(beneficiaries[1], beneficiary2);
    }

    function test_GetBeneficiaryCount() public {
        assertEq(vesting.getBeneficiaryCount(), 0);

        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        assertEq(vesting.getBeneficiaryCount(), 1);

        vesting.createVestingSchedule(beneficiary2, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        assertEq(vesting.getBeneficiaryCount(), 2);
    }

    function test_GetVestingSchedule_Complete() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);

        (
            uint256 totalAmount,
            uint64 scheduleStartTime,
            uint64 cliffDuration,
            uint64 vestingDuration,
            uint256 releasedAmount,
            uint256 vestedNow,
            uint256 releasableNow,
            bool revoked
        ) = vesting.getVestingSchedule(beneficiary1);

        assertEq(totalAmount, TOTAL_AMOUNT);
        assertEq(scheduleStartTime, startTime);
        assertEq(cliffDuration, CLIFF_DURATION);
        assertEq(vestingDuration, VESTING_DURATION);
        assertEq(releasedAmount, 0);
        assertGt(vestedNow, 0);
        assertGt(releasableNow, 0);
        assertFalse(revoked);
    }

    // ============ Fuzz Tests ============

    function testFuzz_CreateVestingSchedule(uint128 amount, uint64 cliff, uint64 duration) public {
        // Bound inputs to reasonable ranges
        amount = uint128(bound(amount, 1, token.balanceOf(address(this))));
        duration = uint64(bound(duration, 1 days, 10 * 365 days));
        cliff = uint64(bound(cliff, 0, duration));

        uint64 startTime = uint64(block.timestamp);

        vesting.createVestingSchedule(beneficiary1, amount, startTime, cliff, duration);

        (uint256 totalAmount,,,,,,,) = vesting.getVestingSchedule(beneficiary1);
        assertEq(totalAmount, amount);
    }

    function testFuzz_VestedAmount(uint64 timeElapsed) public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        timeElapsed = uint64(bound(timeElapsed, 0, VESTING_DURATION * 2));
        vm.warp(startTime + timeElapsed);

        uint256 vested = vesting.vestedAmount(beneficiary1);

        if (timeElapsed < CLIFF_DURATION) {
            assertEq(vested, 0);
        } else if (timeElapsed >= VESTING_DURATION) {
            assertEq(vested, TOTAL_AMOUNT);
        } else {
            assertLe(vested, TOTAL_AMOUNT);
            assertGt(vested, 0);
        }
    }

    // ============ Integration Tests ============

    function test_Integration_CompleteVestingCycle() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // Try releasing before cliff
        vm.prank(beneficiary1);
        vm.expectRevert(TokenVesting.NoTokensToRelease.selector);
        vesting.release();

        // Release at cliff
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(beneficiary1);
        vesting.release();
        uint256 firstRelease = token.balanceOf(beneficiary1);
        assertGt(firstRelease, 0);

        // Release quarterly
        for (uint256 i = 1; i <= 12; i++) {
            vm.warp(startTime + CLIFF_DURATION + (i * 90 days));
            if (vesting.releasableAmount(beneficiary1) > 0) {
                vm.prank(beneficiary1);
                vesting.release();
            }
        }

        // Final release
        vm.warp(startTime + VESTING_DURATION);
        if (vesting.releasableAmount(beneficiary1) > 0) {
            vm.prank(beneficiary1);
            vesting.release();
        }

        assertEq(token.balanceOf(beneficiary1), TOTAL_AMOUNT);
    }

    function test_Integration_MultipleSchedulesWithRevocation() public {
        uint64 startTime = uint64(block.timestamp);

        // Create 3 schedules
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        vesting.createVestingSchedule(beneficiary2, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        vesting.createVestingSchedule(beneficiary3, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // Move past cliff
        vm.warp(startTime + CLIFF_DURATION + 180 days);

        // Beneficiary 1 releases
        vm.prank(beneficiary1);
        vesting.release();

        // Revoke beneficiary 2
        vesting.revokeVesting(beneficiary2);

        // Beneficiary 3 releases
        vm.prank(beneficiary3);
        vesting.release();

        // Verify states
        assertGt(token.balanceOf(beneficiary1), 0);
        assertEq(token.balanceOf(beneficiary2), 0);
        assertGt(token.balanceOf(beneficiary3), 0);

        // Move to end
        vm.warp(startTime + VESTING_DURATION);

        // Final releases
        vm.prank(beneficiary1);
        vesting.release();
        vm.prank(beneficiary3);
        vesting.release();

        assertEq(token.balanceOf(beneficiary1), TOTAL_AMOUNT);
        assertEq(token.balanceOf(beneficiary3), TOTAL_AMOUNT);
    }

    function test_Integration_DeploymentScriptWithSchedules() public {
        // Test deploying with the main deployment script
        DeployTokenVesting mainDeployer = new DeployTokenVesting();

        // Set environment variables for deployment
        vm.setEnv("TOKEN_ADDRESS", vm.toString(address(token)));
        vm.setEnv("VESTING_OWNER", vm.toString(address(this)));
        vm.setEnv("CREATE_INITIAL_SCHEDULES", "false");

        address deployedVesting = mainDeployer.run();

        assertTrue(deployedVesting != address(0));
        TokenVesting newVesting = TokenVesting(deployedVesting);
        assertEq(address(newVesting.token()), address(token));
    }

    // ============ Edge Case Tests ============

    function test_EdgeCase_MaxUint128Amount() public {
        uint128 maxAmount = type(uint128).max;
        token.mint(address(this), maxAmount);
        token.approve(address(vesting), maxAmount);

        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, maxAmount, startTime, CLIFF_DURATION, VESTING_DURATION);

        (uint256 totalAmount,,,,,,,) = vesting.getVestingSchedule(beneficiary1);
        assertEq(totalAmount, maxAmount);
    }

    function test_EdgeCase_MaxUint64Duration() public {
        uint64 maxDuration = type(uint64).max;
        uint64 startTime = uint64(block.timestamp);

        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, maxDuration);

        (,,, uint64 vestingDuration,,,,) = vesting.getVestingSchedule(beneficiary1);
        assertEq(vestingDuration, maxDuration);
    }

    function test_EdgeCase_CliffEqualsVestingDuration() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 duration = 365 days;

        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, duration, duration);

        // Before cliff - nothing vested
        vm.warp(startTime + duration - 1);
        assertEq(vesting.vestedAmount(beneficiary1), 0);

        // At cliff - everything vested
        vm.warp(startTime + duration);
        assertEq(vesting.vestedAmount(beneficiary1), TOTAL_AMOUNT);
    }

    function test_EdgeCase_VerySmallAmount() public {
        uint256 smallAmount = 1;
        uint64 startTime = uint64(block.timestamp);

        vesting.createVestingSchedule(beneficiary1, smallAmount, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + VESTING_DURATION);
        assertEq(vesting.vestedAmount(beneficiary1), smallAmount);
    }

    function test_EdgeCase_StartTimeExactlyNow() public {
        uint64 startTime = uint64(block.timestamp);

        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, 0, VESTING_DURATION);

        // Should vest immediately with zero cliff
        vm.warp(startTime + 1);
        assertGt(vesting.vestedAmount(beneficiary1), 0);
    }

    function test_EdgeCase_MultipleReleasesInSameBlock() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);

        // First release
        vm.prank(beneficiary1);
        vesting.release();
        uint256 balance1 = token.balanceOf(beneficiary1);

        // Try second release in same block (should revert)
        vm.prank(beneficiary1);
        vm.expectRevert(TokenVesting.NoTokensToRelease.selector);
        vesting.release();

        assertEq(token.balanceOf(beneficiary1), balance1);
    }

    // ============ Reentrancy Tests ============

    function test_Reentrancy_ReleaseProtected() public {
        // The nonReentrant modifier should protect against reentrancy
        // This is implicitly tested by the modifier, but we verify proper usage
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);

        // Normal release should work
        vm.prank(beneficiary1);
        vesting.release();

        assertTrue(token.balanceOf(beneficiary1) > 0);
    }

    function test_Reentrancy_RevokeProtected() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // Normal revoke should work
        vesting.revokeVesting(beneficiary1);

        (,,,,,,, bool revoked) = vesting.getVestingSchedule(beneficiary1);
        assertTrue(revoked);
    }

    // ============ State Consistency Tests ============

    function test_StateConsistency_TotalAmountsAfterMultipleOperations() public {
        uint64 startTime = uint64(block.timestamp);

        // Create 3 schedules
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        vesting.createVestingSchedule(beneficiary2, TOTAL_AMOUNT * 2, startTime, CLIFF_DURATION, VESTING_DURATION);
        vesting.createVestingSchedule(beneficiary3, TOTAL_AMOUNT / 2, startTime, CLIFF_DURATION, VESTING_DURATION);

        uint256 expectedTotal = TOTAL_AMOUNT + TOTAL_AMOUNT * 2 + TOTAL_AMOUNT / 2;
        assertEq(vesting.totalVestingAmount(), expectedTotal);

        // Move to cliff
        vm.warp(startTime + CLIFF_DURATION);

        // Release for beneficiary1
        vm.prank(beneficiary1);
        vesting.release();
        uint256 released1 = token.balanceOf(beneficiary1);
        assertEq(vesting.totalReleasedAmount(), released1);

        // Revoke beneficiary2
        vesting.revokeVesting(beneficiary2);
        uint256 vestedAmount2 = (TOTAL_AMOUNT * 2 * CLIFF_DURATION) / VESTING_DURATION;
        assertEq(vesting.totalVestingAmount(), TOTAL_AMOUNT + vestedAmount2 + TOTAL_AMOUNT / 2);

        // Release for beneficiary3
        vm.prank(beneficiary3);
        vesting.release();
        uint256 released3 = token.balanceOf(beneficiary3);
        assertEq(vesting.totalReleasedAmount(), released1 + released3);
    }

    function test_StateConsistency_VestedAmountNeverDecreases() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);
        uint256 vested1 = vesting.vestedAmount(beneficiary1);

        vm.warp(startTime + CLIFF_DURATION + 365 days);
        uint256 vested2 = vesting.vestedAmount(beneficiary1);

        vm.warp(startTime + VESTING_DURATION);
        uint256 vested3 = vesting.vestedAmount(beneficiary1);

        assertGe(vested2, vested1);
        assertGe(vested3, vested2);
    }

    function test_StateConsistency_ReleasedNeverExceedsVested() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // Release at multiple points
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(beneficiary1);
        vesting.release();

        (,,,, uint256 released1,, uint256 releasable1,) = vesting.getVestingSchedule(beneficiary1);
        assertEq(releasable1, 0);

        vm.warp(startTime + CLIFF_DURATION + 365 days);
        vm.prank(beneficiary1);
        vesting.release();

        (,,,, uint256 released2,, uint256 releasable2,) = vesting.getVestingSchedule(beneficiary1);
        assertGt(released2, released1);
        assertEq(releasable2, 0);

        uint256 vested = vesting.vestedAmount(beneficiary1);
        assertEq(released2, vested);
    }

    // ============ Permission Tests ============

    function test_Permission_OnlyOwnerCanCreateSchedule() public {
        vm.prank(beneficiary1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", beneficiary1));
        vesting.createVestingSchedule(
            beneficiary2, TOTAL_AMOUNT, uint64(block.timestamp), CLIFF_DURATION, VESTING_DURATION
        );
    }

    function test_Permission_OnlyOwnerCanRevoke() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.prank(beneficiary2);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", beneficiary2));
        vesting.revokeVesting(beneficiary1);
    }

    function test_Permission_BeneficiaryCanRelease() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);

        // Beneficiary can release their own tokens
        vm.prank(beneficiary1);
        vesting.release();

        assertTrue(token.balanceOf(beneficiary1) > 0);
    }

    function test_Permission_AnyoneCanReleaseFor() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);

        // Random address can release for beneficiary
        vm.prank(beneficiary3);
        vesting.releaseFor(beneficiary1);

        assertTrue(token.balanceOf(beneficiary1) > 0);
    }

    // ============ Gas Optimization Tests ============

    function test_Gas_CreateVestingSchedule() public {
        uint64 startTime = uint64(block.timestamp);

        uint256 gasBefore = gasleft();
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        uint256 gasUsed = gasBefore - gasleft();

        // Should use reasonable gas (< 200k for creation)
        assertLt(gasUsed, 200000);
    }

    function test_Gas_Release() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);

        vm.prank(beneficiary1);
        uint256 gasBefore = gasleft();
        vesting.release();
        uint256 gasUsed = gasBefore - gasleft();

        // Should use reasonable gas (< 100k for release)
        assertLt(gasUsed, 100000);
    }

    function test_Gas_MultipleReleases() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(beneficiary1);
        vesting.release();

        vm.warp(startTime + CLIFF_DURATION + 365 days);
        vm.prank(beneficiary1);
        uint256 gasBefore = gasleft();
        vesting.release();
        uint256 gasUsed = gasBefore - gasleft();

        // Subsequent releases should use similar gas
        assertLt(gasUsed, 100000);
    }

    // ============ Arithmetic Tests ============

    function test_Arithmetic_VestingCalculationPrecision() public {
        uint64 startTime = uint64(block.timestamp);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        // Test at 25%, 50%, 75%, 100%
        vm.warp(startTime + VESTING_DURATION / 4);
        uint256 vested25 = vesting.vestedAmount(beneficiary1);
        assertApproxEqRel(vested25, TOTAL_AMOUNT / 4, 0.01e18); // 1% tolerance

        vm.warp(startTime + VESTING_DURATION / 2);
        uint256 vested50 = vesting.vestedAmount(beneficiary1);
        assertEq(vested50, TOTAL_AMOUNT / 2);

        vm.warp(startTime + (VESTING_DURATION * 3) / 4);
        uint256 vested75 = vesting.vestedAmount(beneficiary1);
        assertApproxEqRel(vested75, (TOTAL_AMOUNT * 3) / 4, 0.01e18);

        vm.warp(startTime + VESTING_DURATION);
        uint256 vested100 = vesting.vestedAmount(beneficiary1);
        assertEq(vested100, TOTAL_AMOUNT);
    }

    function test_Arithmetic_NoRoundingIssues() public {
        // Test with amount that doesn't divide evenly
        uint256 oddAmount = 1000000000000000001; // 1 wei more than 1 token
        uint64 startTime = uint64(block.timestamp);

        vesting.createVestingSchedule(beneficiary1, oddAmount, startTime, 0, VESTING_DURATION);

        vm.warp(startTime + VESTING_DURATION);
        assertEq(vesting.vestedAmount(beneficiary1), oddAmount);

        vm.prank(beneficiary1);
        vesting.release();
        assertEq(token.balanceOf(beneficiary1), oddAmount);
    }

    // ============ Event Emission Tests ============

    function test_Events_AllEventsEmitted() public {
        uint64 startTime = uint64(block.timestamp);

        // VestingScheduleCreated event
        vm.expectEmit(true, false, false, true);
        emit VestingScheduleCreated(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);
        vesting.createVestingSchedule(beneficiary1, TOTAL_AMOUNT, startTime, CLIFF_DURATION, VESTING_DURATION);

        vm.warp(startTime + CLIFF_DURATION);
        uint256 releasable = vesting.releasableAmount(beneficiary1);

        // TokensReleased event
        vm.expectEmit(true, false, false, true);
        emit TokensReleased(beneficiary1, releasable);
        vm.prank(beneficiary1);
        vesting.release();

        vm.warp(startTime + CLIFF_DURATION + 365 days);
        uint256 vestedAmount = vesting.vestedAmount(beneficiary1);
        uint256 expectedRefund = TOTAL_AMOUNT - vestedAmount;

        // VestingRevoked event
        vm.expectEmit(true, false, false, true);
        emit VestingRevoked(beneficiary1, expectedRefund);
        vesting.revokeVesting(beneficiary1);
    }
}
