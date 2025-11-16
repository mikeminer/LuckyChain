// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    LuckyChain – SuperEnalotto On-Chain
    Network: Base Sepolia (testnet)

    - Ticket cost: 1 USDC (6 decimals)
    - 6 numbers (1–90) + Jolly (1–90) + Superstar (1–90)
    - Max 100 tickets per round
    - When the 100th ticket is bought:
        * Request randomness via Chainlink VRF v2.5
        * Draw 6 winning numbers + 1 Jolly + 1 Superstar
        * If no 6/6 winners → jackpot rolls over

    Chainlink VRF v2.5 (Base Sepolia):
    - VRF Coordinator: 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE
    - Key Hash (30 gwei):
      0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71

    USDC (testnet):
    - 0x036CbD53842c5426634e7929541eC2318f3dCF7e
*/

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LuckyChainVRF_BaseSepolia is VRFConsumerBaseV2 {
    // -------------------------
    // Types
    // -------------------------

    struct Ticket {
        address player;
        uint8[6] numbers;
        uint8 jolly;
        uint8 superstar;
    }

    struct RoundResult {
        bool drawn;
        uint8[6] winningNumbers;
        uint8 winningJolly;
        uint8 winningSuperstar;
    }

    // -------------------------
    // Constants
    // -------------------------

    uint8 public constant NUMBERS_PER_TICKET = 6;
    uint8 public constant MAX_NUMBER = 90;
    uint256 public constant TICKET_PRICE_USDC = 1_000_000; // 1 USDC (6 decimals)
    uint256 public constant TICKETS_PER_ROUND = 100;
    uint32 public constant NUM_WORDS = 8; // 6 numbers + jolly + superstar

    // -------------------------
    // State
    // -------------------------

    IERC20 public immutable usdc;
    VRFCoordinatorV2Interface public immutable COORDINATOR;

    address public owner;

    uint256 public subscriptionId;       // !!
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 300_000;
    uint16 public requestConfirmations = 3;

    uint256 public currentRound = 1;
    uint256 public ticketsInCurrentRound;
    uint256 public jackpot;

    mapping(uint256 => mapping(uint256 => Ticket)) public tickets;
    mapping(uint256 => uint256) public ticketsPerRound;

    mapping(uint256 => RoundResult) public roundResults;

    mapping(uint256 => uint256) public requestIdToRound;

    uint256 public lastDrawnRound;

    // -------------------------
    // Events
    // -------------------------

    event TicketBought(uint256 indexed round, uint256 indexed ticketId, address indexed player);
    event DrawRequested(uint256 indexed round, uint256 requestId);
    event DrawCompleted(uint256 indexed round, uint8[6] winningNumbers, uint8 jolly, uint8 superstar);
    event JackpotPaid(uint256 indexed round, uint256 totalPaid, uint256 winners);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    // -------------------------
    // Modifiers
    // -------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // -------------------------
    // Constructor
    // -------------------------

    constructor(uint256 _subscriptionId)
        VRFConsumerBaseV2(
            0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE // VRF Coordinator Base Sepolia
        )
    {
        owner = msg.sender;

        subscriptionId = _subscriptionId;
        keyHash = 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71;

        COORDINATOR = VRFCoordinatorV2Interface(
            0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE
        );

        usdc = IERC20(0x036CbD53842c5426634e7929541eC2318f3dCF7e);
    }

    // -------------------------
    // USER: Buy Ticket
    // -------------------------

    function buyTicket(
        uint8[6] calldata nums,
        uint8 jolly,
        uint8 superstar
    ) external {
        require(ticketsInCurrentRound < TICKETS_PER_ROUND, "Round full");

        _validateNumbers(nums);
        _validateSingle(jolly);
        _validateSingle(superstar);

        require(
            usdc.transferFrom(msg.sender, address(this), TICKET_PRICE_USDC),
            "USDC transfer failed"
        );

        jackpot += TICKET_PRICE_USDC;
        ticketsInCurrentRound++;

        tickets[currentRound][ticketsInCurrentRound] = Ticket(
            msg.sender,
            nums,
            jolly,
            superstar
        );

        ticketsPerRound[currentRound] = ticketsInCurrentRound;

        emit TicketBought(currentRound, ticketsInCurrentRound, msg.sender);

        if (ticketsInCurrentRound == TICKETS_PER_ROUND) {
            _requestRandomWords();
        }
    }

    // -------------------------
    // VRF Logic
    // -------------------------

    function _requestRandomWords() internal {
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            uint64(subscriptionId), // cast safe
            requestConfirmations,
            callbackGasLimit,
            NUM_WORDS
        );

        requestIdToRound[requestId] = currentRound;

        emit DrawRequested(currentRound, requestId);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        uint256 round = requestIdToRound[requestId];
        require(round != 0, "Unknown request");

        RoundResult storage result = roundResults[round];
        require(!result.drawn, "Already drawn");

        for (uint8 i = 0; i < NUMBERS_PER_TICKET; i++) {
            result.winningNumbers[i] = uint8((randomWords[i] % MAX_NUMBER) + 1);
        }

        result.winningJolly = uint8((randomWords[6] % MAX_NUMBER) + 1);
        result.winningSuperstar = uint8((randomWords[7] % MAX_NUMBER) + 1);

        result.drawn = true;

        emit DrawCompleted(round, result.winningNumbers, result.winningJolly, result.winningSuperstar);

        _payoutJackpot(round);

        lastDrawnRound = round;

        currentRound++;
        ticketsInCurrentRound = 0;
    }

    // -------------------------
    // Payout Logic
    // -------------------------

    function _payoutJackpot(uint256 round) internal {
        uint256 ticketCount = ticketsPerRound[round];
        if (ticketCount == 0) return;

        RoundResult storage result = roundResults[round];

        uint256 winners = 0;
        for (uint256 i = 1; i <= ticketCount; i++) {
            if (_countMatches(tickets[round][i].numbers, result.winningNumbers) == NUMBERS_PER_TICKET) {
                winners++;
            }
        }

        if (winners == 0) {
            emit JackpotPaid(round, 0, 0);
            return;
        }

        uint256 share = jackpot / winners;

        for (uint256 i = 1; i <= ticketCount; i++) {
            if (_countMatches(tickets[round][i].numbers, result.winningNumbers) == NUMBERS_PER_TICKET) {
                usdc.transfer(tickets[round][i].player, share);
            }
        }

        emit JackpotPaid(round, jackpot, winners);

        jackpot = 0;
    }

    // -------------------------
    // Views
    // -------------------------

    function getCurrentRoundInfo()
        external
        view
        returns (
            uint256 roundId,
            uint256 ticketsSold,
            uint256 currentJackpot,
            bool isDrawn,
            uint8[6] memory nums,
            uint8 jolly,
            uint8 superstar
        )
    {
        roundId = currentRound;
        ticketsSold = ticketsInCurrentRound;
        currentJackpot = jackpot;

        RoundResult storage r = roundResults[currentRound];
        isDrawn = r.drawn;
        nums = r.winningNumbers;
        jolly = r.winningJolly;
        superstar = r.winningSuperstar;
    }

    function getLastDrawInfo()
        external
        view
        returns (
            uint256 roundId,
            uint8[6] memory nums,
            uint8 jolly,
            uint8 superstar,
            bool drawn
        )
    {
        roundId = lastDrawnRound;

        if (roundId == 0) {
            uint8[6] memory empty;
            return (0, empty, 0, 0, false);
        }

        RoundResult storage r = roundResults[roundId];
        return (roundId, r.winningNumbers, r.winningJolly, r.winningSuperstar, r.drawn);
    }

    // -------------------------
    // Helpers
    // -------------------------

    function _countMatches(uint8[6] memory a, uint8[6] memory b)
        internal
        pure
        returns (uint8 m)
    {
        for (uint8 i = 0; i < 6; i++) {
            for (uint8 j = 0; j < 6; j++) {
                if (a[i] == b[j]) {
                    m++;
                    break;
                }
            }
        }
    }

    function _validateNumbers(uint8[6] calldata nums) internal pure {
        for (uint8 i = 0; i < 6; i++) {
            require(nums[i] >= 1 && nums[i] <= MAX_NUMBER, "Num out of range");
            for (uint8 j = i + 1; j < 6; j++) {
                require(nums[i] != nums[j], "Duplicate number");
            }
        }
    }

    function _validateSingle(uint8 n) internal pure {
        require(n >= 1 && n <= MAX_NUMBER, "Invalid number");
    }

    // -------------------------
    // Admin
    // -------------------------

    function setCallbackGasLimit(uint32 _limit) external onlyOwner {
        callbackGasLimit = _limit;
    }

    function setRequestConfirmations(uint16 _conf) external onlyOwner {
        requestConfirmations = _conf;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero addr");
        IERC20(token).transfer(to, amount);
    }
}
