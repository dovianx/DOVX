// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Importing OpenZeppelin upgradeable contracts
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

/**
 * @title DovianX - Ultimate ERC20 Token with Governance and Tokenomics
 * @dev Upgradeable ERC20 token with rebasing, fees, carbon offset, batch minting, and enhanced governance.
 */
contract DovianX is 
    Initializable, 
    ERC20Upgradeable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable 
{
    using AddressUpgradeable for address;

    // --- Constants ---
    uint256 public constant MAX_SUPPLY = 100_000_000_000 * 10**18; // 100 billion tokens
    uint256 public constant TIMELOCK_DELAY = 2 days; // 2-day timelock for governance actions
    uint256 public constant MAX_FEE = 500; // 5% max fee in basis points
    uint256 public constant MAX_REBASE_FACTOR = 2e18; // 2x max rebase factor
    uint256 private constant INITIAL_MINT = 10_000_000_000 * 10**18; // 10% initial mint

    // --- Roles ---
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // --- State Variables ---
    uint256 public totalBurned;
    address public treasury;
    address public burnDestination;
    uint256 public carbonOffsetPool;
    uint256 public rebaseFactor;
    address public governanceContract; // Placeholder for future DAO integration

    struct FeeConfig {
        uint128 transactionFee; // Basis points (e.g., 100 = 1%)
        uint128 baseFee;        // Percentage of transfer amount in wei precision
        uint128 autoBurnRate;   // Portion for carbon offset
        uint128 devFundRate;    // Portion for treasury/dev fund
    }
    FeeConfig public fees;

    struct TimelockAction {
        uint96 executionTime;
        bool executed;
        bytes data; // Encoded function call for execution
    }
    mapping(bytes32 => TimelockAction) public timelockActions;

    // --- Events ---
    event FeeUpdated(uint128 transactionFee, uint128 baseFee, uint128 autoBurnRate, uint128 devFundRate);
    event TreasuryUpdated(address newTreasury);
    event BurnDestinationUpdated(address newBurnDestination);
    event TokensBurned(address indexed burner, uint256 amount);
    event ActionScheduled(bytes32 indexed actionHash, uint256 executionTime);
    event ActionExecuted(bytes32 indexed actionHash);
    event Rebase(uint256 newFactor);
    event TokensMinted(address indexed to, uint256 amount);
    event BatchMinted(uint256 recipientCount, uint256 totalAmount);
    event UpgradeScheduled(address newImplementation);
    event CarbonOffsetWithdrawn(address indexed to, uint256 amount);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    // --- Initializer ---
    function initialize() external initializer {
        address initialOwner = 0xf7ea4B2CfF887917760Ff2c70194D1e493C24860;
        __ERC20_init("DovianX", "DOVX");
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(GOVERNOR_ROLE, initialOwner);
        _grantRole(UPGRADER_ROLE, initialOwner);
        _grantRole(MINTER_ROLE, initialOwner);

        treasury = initialOwner;
        burnDestination = address(0xdead);
        rebaseFactor = 1e18;
        fees = FeeConfig(100, 5e16, 5e17, 2e17); // 1% tx fee, 0.5% base, 5% carbon, 2% dev

        // Mint initial supply to owner
        _mint(initialOwner, INITIAL_MINT);
        emit TokensMinted(initialOwner, INITIAL_MINT);
    }

    // --- Token Transfer Hook ---
    function _beforeTokenTransfer(address from, address to, uint256 amount) 
        internal 
        whenNotPaused 
        
    {
        require(from != address(0) && to != address(0), "DovianX: Invalid address");
        require(amount > 0, "DovianX: Zero transfer amount");

        uint256 adjustedAmount = (amount * rebaseFactor) / 1e18;
        FeeConfig memory f = fees;
        uint256 totalFee = _calculateTotalFee(adjustedAmount, f);
        require(adjustedAmount >= totalFee, "DovianX: Insufficient balance for fees");

        if (totalFee > 0) {
            _applyFees(from, adjustedAmount, f);
        }
    }

    // --- Minting ---
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        require(to != address(0), "DovianX: Invalid recipient");
        require(totalSupply() + amount <= MAX_SUPPLY, "DovianX: Exceeds max supply");
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    function batchMint(address[] calldata recipients, uint256[] calldata amounts) 
        external onlyRole(MINTER_ROLE) whenNotPaused {
        require(recipients.length == amounts.length, "DovianX: Array length mismatch");
        uint256 totalAmount;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "DovianX: Invalid recipient");
            totalAmount += amounts[i];
            _mint(recipients[i], amounts[i]);
            emit TokensMinted(recipients[i], amounts[i]);
        }
        require(totalSupply() <= MAX_SUPPLY, "DovianX: Exceeds max supply");
        emit BatchMinted(recipients.length, totalAmount);
    }

    // --- Rebasing ---
    function scheduleRebase(uint256 newFactor) external onlyRole(GOVERNOR_ROLE) {
        require(newFactor >= 1e18 / 2 && newFactor <= MAX_REBASE_FACTOR, "DovianX: Invalid rebase factor");
        bytes memory data = abi.encodeWithSignature("executeRebase(uint256)", newFactor);
        bytes32 actionHash = keccak256(abi.encode("REBASE", newFactor));
        _scheduleAction(actionHash, data);
    }

    function executeRebase(uint256 newFactor) external nonReentrant {
        bytes32 actionHash = keccak256(abi.encode("REBASE", newFactor));
        _executeAction(actionHash);
        rebaseFactor = newFactor;
        emit Rebase(newFactor);
    }

    // --- Fee Management ---
    function scheduleFeeUpdate(
        uint128 transactionFee,
        uint128 baseFee,
        uint128 autoBurnRate,
        uint128 devFundRate
    ) external onlyRole(GOVERNOR_ROLE) {
        require(transactionFee + (baseFee + autoBurnRate + devFundRate) / 1e16 <= MAX_FEE, "DovianX: Fees exceed max");
        bytes memory data = abi.encodeWithSignature(
            "executeFeeUpdate(uint128,uint128,uint128,uint128)",
            transactionFee, baseFee, autoBurnRate, devFundRate
        );
        bytes32 actionHash = keccak256(abi.encode("FEE_UPDATE", transactionFee, baseFee, autoBurnRate, devFundRate));
        _scheduleAction(actionHash, data);
    }

    function executeFeeUpdate(
        uint128 transactionFee,
        uint128 baseFee,
        uint128 autoBurnRate,
        uint128 devFundRate
    ) external nonReentrant {
        bytes32 actionHash = keccak256(abi.encode("FEE_UPDATE", transactionFee, baseFee, autoBurnRate, devFundRate));
        _executeAction(actionHash);
        fees = FeeConfig(transactionFee, baseFee, autoBurnRate, devFundRate);
        emit FeeUpdated(transactionFee, baseFee, autoBurnRate, devFundRate);
    }

    function _calculateTotalFee(uint256 amount, FeeConfig memory f) internal pure returns (uint256) {
        return (amount * f.transactionFee) / 10000 + 
               (amount * (f.baseFee + f.autoBurnRate + f.devFundRate)) / 1e18;
    }

    function _applyFees(address from, uint256 adjustedAmount, FeeConfig memory f) internal {
        uint256 txFee = (adjustedAmount * f.transactionFee) / 10000;
        uint256 baseFeeAmt = (adjustedAmount * f.baseFee) / 1e18;
        uint256 carbonFee = (adjustedAmount * f.autoBurnRate) / 1e18;
        uint256 devFee = (adjustedAmount * f.devFundRate) / 1e18;

        if (baseFeeAmt > 0) {
            _burn(from, baseFeeAmt);
            totalBurned += baseFeeAmt;
            emit TokensBurned(from, baseFeeAmt);
        }
        if (carbonFee > 0) {
            carbonOffsetPool += carbonFee;
            _transfer(from, address(this), carbonFee); // Store in contract for later allocation
        }
        if (devFee > 0 || txFee > 0) {
            _transfer(from, treasury, devFee + txFee);
        }
    }

    // --- Carbon Offset Management ---
    function withdrawCarbonOffset(address to, uint256 amount) external onlyRole(GOVERNOR_ROLE) nonReentrant {
        require(to != address(0), "DovianX: Invalid recipient");
        require(amount <= carbonOffsetPool, "DovianX: Insufficient pool balance");
        carbonOffsetPool -= amount;
        _transfer(address(this), to, amount);
        emit CarbonOffsetWithdrawn(to, amount);
    }

    // --- Timelock Functions ---
    function _scheduleAction(bytes32 actionHash, bytes memory data) internal {
        require(timelockActions[actionHash].executionTime == 0, "DovianX: Action already scheduled");
        uint96 executionTime = uint96(block.timestamp + TIMELOCK_DELAY);
        timelockActions[actionHash] = TimelockAction(executionTime, false, data);
        emit ActionScheduled(actionHash, executionTime);
    }

    function _executeAction(bytes32 actionHash) internal {
        TimelockAction storage action = timelockActions[actionHash];
        require(action.executionTime > 0, "DovianX: Action not scheduled");
        require(block.timestamp >= action.executionTime, "DovianX: Timelock not expired");
        require(!action.executed, "DovianX: Action already executed");

        action.executed = true;
        (bool success, ) = address(this).call(action.data);
        require(success, "DovianX: Action execution failed");
        emit ActionExecuted(actionHash);
    }

    // --- Upgradeability ---
    function scheduleUpgrade(address newImplementation) external onlyRole(UPGRADER_ROLE) {
        require(newImplementation.isContract(), "DovianX: Not a contract");
        bytes memory data = abi.encodeWithSignature("_authorizeUpgrade(address)", newImplementation);
        bytes32 actionHash = keccak256(abi.encode("UPGRADE", newImplementation));
        _scheduleAction(actionHash, data);
        emit UpgradeScheduled(newImplementation);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        bytes32 actionHash = keccak256(abi.encode("UPGRADE", newImplementation));
        _executeAction(actionHash);
    }

    // --- Admin Functions ---
    function updateTreasury(address newTreasury) external onlyRole(GOVERNOR_ROLE) {
        require(newTreasury != address(0), "DovianX: Invalid treasury");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function updateBurnDestination(address newBurnDestination) external onlyRole(GOVERNOR_ROLE) {
        require(newBurnDestination != address(0), "DovianX: Invalid burn address");
        burnDestination = newBurnDestination;
        emit BurnDestinationUpdated(newBurnDestination);
    }

    function updateGovernanceContract(address newGovernance) external onlyRole(GOVERNOR_ROLE) {
        require(newGovernance != address(0), "DovianX: Invalid address");
        governanceContract = newGovernance;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // --- Emergency Withdrawal ---
    function emergencyWithdraw(address token, uint256 amount) 
        external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(amount > 0, "DovianX: Invalid amount");
        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "DovianX: ETH transfer failed");
        } else {
            ERC20Upgradeable(token).transfer(msg.sender, amount);
        }
        emit EmergencyWithdrawal(token, msg.sender, amount);
    }

    // --- View Functions ---
    function version() external pure returns (string memory) {
        return "1.3.0"; // Hybrid version
    }

    // --- Fallback to receive ETH ---
    receive() external payable {}
}
