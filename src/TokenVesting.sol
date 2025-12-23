// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title TokenVesting
 * @author Therock Ani
 * @dev Industry-standard token vesting contract with cliff periods
 * Implements best practices from major protocols (Uniswap, Compound, etc.)
 */
contract TokenVesting is Context, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Errors ============

    error InvalidTokenAddress();
    error InvalidBeneficiary();
    error InvalidAmount();
    error InvalidVestingDuration();
    error CliffExceedsVestingDuration();
    error VestingScheduleExists();
    error InvalidStartTime();
    error VestingScheduleNotFound();
    error VestingAlreadyRevoked();
    error NoTokensToRelease();
    error Unauthorized();

    // ============ State Variables ============

    IERC20 public immutable token;

    struct VestingSchedule {
        uint128 totalAmount; // Total tokens to be vested (uint128 for gas optimization)
        uint128 releasedAmount; // Amount already released
        uint64 startTime; // Vesting start timestamp
        uint64 cliffDuration; // Cliff period in seconds
        uint64 vestingDuration; // Total vesting duration in seconds
        bool revoked; // Whether vesting was revoked
    }

    mapping(address => VestingSchedule) public vestingSchedules;
    address[] private _beneficiaries;

    uint256 public totalVestingAmount;
    uint256 public totalReleasedAmount;

    // ============ Events ============

    event VestingScheduleCreated(
        address indexed beneficiary, uint256 totalAmount, uint64 startTime, uint64 cliffDuration, uint64 vestingDuration
    );

    event TokensReleased(address indexed beneficiary, uint256 amount);

    event VestingRevoked(address indexed beneficiary, uint256 refundAmount);

    // ============ Constructor ============

    constructor(address tokenAddress) Ownable(_msgSender()) {
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        token = IERC20(tokenAddress);
    }

    // ============ External Functions ============

    /**
     * @notice Creates a vesting schedule for a beneficiary
     * @dev Only callable by owner. Follows checks-effects-interactions pattern
     * @param beneficiary Address of the team member
     * @param totalAmount Total tokens to vest
     * @param startTime When vesting starts (unix timestamp)
     * @param cliffDuration Cliff period in seconds
     * @param vestingDuration Total vesting duration in seconds
     */
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint64 startTime,
        uint64 cliffDuration,
        uint64 vestingDuration
    ) external onlyOwner {
        // Input validation
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (totalAmount == 0) revert InvalidAmount();
        if (vestingDuration == 0) revert InvalidVestingDuration();
        if (cliffDuration > vestingDuration) revert CliffExceedsVestingDuration();
        if (vestingSchedules[beneficiary].totalAmount != 0) revert VestingScheduleExists();
        if (startTime < block.timestamp) revert InvalidStartTime();

        // Ensure amounts fit in uint128
        if (totalAmount > type(uint128).max) revert InvalidAmount();

        // Effects
        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: uint128(totalAmount),
            releasedAmount: 0,
            startTime: startTime,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            revoked: false
        });

        _beneficiaries.push(beneficiary);
        totalVestingAmount += totalAmount;

        emit VestingScheduleCreated(beneficiary, totalAmount, startTime, cliffDuration, vestingDuration);

        // Interactions (last)
        token.safeTransferFrom(_msgSender(), address(this), totalAmount);
    }

    /**
     * @notice Release vested tokens to beneficiary
     * @dev Beneficiary calls this to claim their vested tokens
     */
    function release() external nonReentrant {
        _release(_msgSender());
    }

    /**
     * @notice Release tokens on behalf of a beneficiary
     * @dev Can be called by anyone to release tokens to a beneficiary
     * @param beneficiary Address to release tokens for
     */
    function releaseFor(address beneficiary) external nonReentrant {
        _release(beneficiary);
    }

    /**
     * @notice Revoke vesting schedule
     * @dev Only callable by owner. Unvested tokens are returned to owner
     * @param beneficiary Address whose vesting to revoke
     */
    function revokeVesting(address beneficiary) external onlyOwner nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];

        if (schedule.totalAmount == 0) revert VestingScheduleNotFound();
        if (schedule.revoked) revert VestingAlreadyRevoked();

        uint256 vested = _computeVestedAmount(schedule);
        uint256 refund = uint256(schedule.totalAmount) - vested;

        // Effects
        schedule.revoked = true;
        totalVestingAmount -= refund;

        emit VestingRevoked(beneficiary, refund);

        // Interactions
        if (refund > 0) {
            token.safeTransfer(owner(), refund);
        }
    }

    // ============ Public View Functions ============

    /**
     * @notice Calculate the vested amount for a beneficiary
     * @param beneficiary Address to check
     * @return The amount of tokens vested
     */
    function vestedAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule memory schedule = vestingSchedules[beneficiary];

        if (schedule.totalAmount == 0) return 0;
        if (schedule.revoked) return schedule.releasedAmount;

        return _computeVestedAmount(schedule);
    }

    /**
     * @notice Calculate releasable amount for a beneficiary
     * @param beneficiary Address to check
     * @return The amount that can be released
     */
    function releasableAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule memory schedule = vestingSchedules[beneficiary];
        if (schedule.totalAmount == 0) return 0;

        uint256 vested = vestedAmount(beneficiary);
        return vested - schedule.releasedAmount;
    }

    /**
     * @notice Get all beneficiaries
     * @return Array of beneficiary addresses
     */
    function getBeneficiaries() external view returns (address[] memory) {
        return _beneficiaries;
    }

    /**
     * @notice Get comprehensive vesting schedule details
     * @param beneficiary Address to query
     * @return totalAmount Total tokens to be vested
     * @return startTime Vesting start timestamp
     * @return cliffDuration Cliff period in seconds
     * @return vestingDuration Total vesting duration in seconds
     * @return releasedAmount Amount already released
     * @return vestedNow Amount vested up to now
     * @return releasableNow Amount releasable now
     * @return revoked Whether vesting was revoked
     */
    function getVestingSchedule(address beneficiary)
        external
        view
        returns (
            uint256 totalAmount,
            uint64 startTime,
            uint64 cliffDuration,
            uint64 vestingDuration,
            uint256 releasedAmount,
            uint256 vestedNow,
            uint256 releasableNow,
            bool revoked
        )
    {
        VestingSchedule memory schedule = vestingSchedules[beneficiary];
        return (
            schedule.totalAmount,
            schedule.startTime,
            schedule.cliffDuration,
            schedule.vestingDuration,
            schedule.releasedAmount,
            vestedAmount(beneficiary),
            releasableAmount(beneficiary),
            schedule.revoked
        );
    }

    /**
     * @notice Get the number of beneficiaries
     * @return Count of beneficiaries
     */
    function getBeneficiaryCount() external view returns (uint256) {
        return _beneficiaries.length;
    }

    // ============ Internal Functions ============

    /**
     * @dev Internal function to release vested tokens
     * @param beneficiary Address to release tokens for
     */
    function _release(address beneficiary) private {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];

        if (schedule.totalAmount == 0) revert VestingScheduleNotFound();
        if (schedule.revoked) revert VestingAlreadyRevoked();

        uint256 amount = releasableAmount(beneficiary);
        if (amount == 0) revert NoTokensToRelease();

        // Effects
        schedule.releasedAmount += uint128(amount);
        totalReleasedAmount += amount;

        emit TokensReleased(beneficiary, amount);

        // Interactions
        token.safeTransfer(beneficiary, amount);
    }

    /**
     * @dev Compute vested amount based on vesting schedule
     * @param schedule The vesting schedule to compute for
     * @return The vested amount
     */
    function _computeVestedAmount(VestingSchedule memory schedule) private view returns (uint256) {
        uint64 currentTime = uint64(block.timestamp);

        // Before cliff
        if (currentTime < schedule.startTime + schedule.cliffDuration) {
            return 0;
        }

        // After vesting period
        if (currentTime >= schedule.startTime + schedule.vestingDuration) {
            return schedule.totalAmount;
        }

        // Linear vesting between cliff and end
        uint256 timeVested = currentTime - schedule.startTime;
        return (uint256(schedule.totalAmount) * timeVested) / schedule.vestingDuration;
    }
}
