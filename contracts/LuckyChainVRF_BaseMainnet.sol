// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    LuckyChain – SuperEnalotto On-Chain
    Network: Base Mainnet

    - Ticket cost: 1 USDC (6 decimals)
    - 6 numbers (1–90) + Jolly (1–90) + Superstar (1–90)
    - Max 100 tickets per round
    - When the 100th ticket is bought:
        * Request randomness via Chainlink VRF v2.5
        * Draw 6 winning numbers + 1 Jolly + 1 Superstar
        * Find all tickets with 6/6 matches
        * Split the whole jackpot equally across all 6/6 winners
        * If no 6/6 winners, jackpot rolls over to next round

    Chainlink VRF v2.5 (Base Mainnet):
    - VRF Coordinator: 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634
    - Key Hash (30 gwei):
      0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70

    USDC on Base Mainnet (6 decimals):
    - 0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913
*/

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LuckyChainVRF_BaseMainnet is VRFConsumerBaseV2 {
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

    // VRF config
    uint64 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 300_000;
    uint16 public requestConfirmations = 3;

    // Game state
    uint256 public currentRound = 1;
    uint256 public ticketsInCurrentRound;
    uint256 public jackpot; // accumulato in USDC (6 decimals)

    // round => ticketId => Ticket
    mapping(uint256 => mapping(uint256 => Ticket)) public tickets;
    // round => numero di ticket emessi in quel round
    mapping(uint256 => uint256) public ticketsPerRound;

    // Risultati estrazione per round
    mapping(uint256 => RoundResult) public roundResults;

    // VRF requestId => round
    mapping(uint256 => uint256) public requestIdToRound;

    // ultimo round estratto (per UX frontend)
    uint256 public lastDrawnRound;

    // -------------------------
    // Events
    // -------------------------

    event TicketBought(
        uint256 indexed round,
        uint256 indexed ticketId,
        address indexed player
    );

    event DrawRequested(uint256 indexed round, uint256 requestId);

    event DrawCompleted(
        uint256 indexed round,
        uint8[6] winningNumbers,
        uint8 winningJolly,
        uint8 winningSuperstar
    );

    event JackpotPaid(
        uint256 indexed round,
        uint256 totalPaid,
        uint256 winnersCount
    );

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
            // VRF Coordinator v2.5 on Base Mainnet
            0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634
        )
    {
        owner = msg.sender;

        // VRF setup
        subscriptionId = _subscriptionId;
        keyHash = 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;

        COORDINATOR = VRFCoordinatorV2Interface(
            0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634
        );

        // USDC on Base Mainnet (6 decimals)
        usdc = IERC20(0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913);
    }

    // -------------------------
    // User functions
    // -------------------------

    /// @notice Buy one ticket for the current round (cost: 1 USDC).
    /// @param nums 6 distinct numbers between 1 and 90
    /// @param jolly single number 1–90
    /// @param superstar single number 1–90
    function buyTicket(
        uint8[6] calldata nums,
        uint8 jolly,
        uint8 superstar
    ) external {
        require(
            ticketsInCurrentRound < TICKETS_PER_ROUND,
            "Round is full, wait for next"
        );

        _validateNumbers(nums);
        _validateSingle(jolly);
        _validateSingle(superstar);

        // Take 1 USDC from player
        bool ok = usdc.transferFrom(
            msg.sender,
            address(this),
            TICKET_PRICE_USDC
        );
        require(ok, "USDC transfer failed");

        // Update jackpot & ticket count
        jackpot += TICKET_PRICE_USDC;
        ticketsInCurrentRound++;

        // Save ticket
        tickets[currentRound][ticketsInCurrentRound] = Ticket({
            player: msg.sender,
            numbers: nums,
            jolly: jolly,
            superstar: superstar
        });
        ticketsPerRound[currentRound] = ticketsInCurrentRound;

        emit TicketBought(
            currentRound,
            ticketsInCurrentRound,
            msg.sender
        );

        // If this was the 100th ticket, request randomness
        if (ticketsInCurrentRound == TICKETS_PER_ROUND) {
            _requestRandomWords();
        }
    }

    // -------------------------
    // VRF logic
    // -------------------------

    function _requestRandomWords() internal {
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            NUM_WORDS
        );

        requestIdToRound[requestId] = currentRound;

        emit DrawRequested(currentRound, requestId);
    }

    /// @dev VRF callback – called by the VRF coordinator
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        uint256 round = requestIdToRound[requestId];
        require(round != 0, "Unknown request");

        RoundResult storage result = roundResults[round];
        require(!result.drawn, "Already drawn");

        // 6 winning numbers
        for (uint8 i = 0; i < NUMBERS_PER_TICKET; i++) {
            result.winningNumbers[i] = uint8(
                (randomWords[i] % MAX_NUMBER) + 1
            );
        }

        // Jolly
        result.winningJolly = uint8(
            (randomWords[6] % MAX_NUMBER) + 1
        );
        // Superstar
        result.winningSuperstar = uint8(
            (randomWords[7] % MAX_NUMBER) + 1
        );

        result.drawn = true;

        emit DrawCompleted(
            round,
            result.winningNumbers,
            result.winningJolly,
            result.winningSuperstar
        );

        _payoutJackpot(round);

        // aggiorna l'ultimo round estratto per la UX
        lastDrawnRound = round;

        // Prepare next round
        currentRound += 1;
        ticketsInCurrentRound = 0;
    }

    // -------------------------
    // Payout logic
    // -------------------------

    /// @dev Distributes the jackpot to all tickets with 6/6 matches.
    ///      If no one hits 6, jackpot is kept and rolls over.
    function _payoutJackpot(uint256 round) internal {
        uint256 ticketCount = ticketsPerRound[round];
        if (ticketCount == 0) return;

        RoundResult storage result = roundResults[round];

        // First pass: count winners
        uint256 winners = 0;
        for (uint256 i = 1; i <= ticketCount; i++) {
            Ticket storage t = tickets[round][i];
            uint8 matches = _countMatches(t.numbers, result.winningNumbers);
            if (matches == NUMBERS_PER_TICKET) {
                winners++;
            }
        }

        if (winners == 0) {
            // No winners: jackpot stays and rolls over
            emit JackpotPaid(round, 0, 0);
            return;
        }

        uint256 totalJackpot = jackpot;
        uint256 share = totalJackpot / winners;

        // Second pass: pay winners
        for (uint256 i = 1; i <= ticketCount; i++) {
            Ticket storage t = tickets[round][i];
            uint8 matches = _countMatches(t.numbers, result.winningNumbers);
            if (matches == NUMBERS_PER_TICKET) {
                usdc.transfer(t.player, share);
            }
        }

        jackpot = 0;

        emit JackpotPaid(round, totalJackpot, winners);
    }

    // -------------------------
    // Views / helpers
    // -------------------------

    /// @notice Returns basic info about the *current* round (ancora aperto).
    function getCurrentRoundInfo()
        external
        view
        returns (
            uint256 roundId,
            uint256 ticketsSold,
            uint256 currentJackpot,
            bool isDrawn,
            uint8[6] memory winNums,
            uint8 jolly,
            uint8 superstar
        )
    {
        roundId = currentRound;
        ticketsSold = ticketsInCurrentRound;
        currentJackpot = jackpot;

        RoundResult storage res = roundResults[currentRound];
        isDrawn = res.drawn;
        winNums = res.winningNumbers;
        jolly = res.winningJolly;
        superstar = res.winningSuperstar;
    }

    /// @notice Returns info about the *last drawn* round (per UX frontend).
    function getLastDrawInfo()
        external
        view
        returns (
            uint256 roundId,
            uint8[6] memory winNums,
            uint8 jolly,
            uint8 superstar,
            bool drawn
        )
    {
        roundId = lastDrawnRound;
        if (roundId == 0) {
            // nessuna estrazione ancora fatta, ritorna default
            return (0, winNums, 0, 0, false);
        }

        RoundResult storage res = roundResults[roundId];
        winNums = res.winningNumbers;
        jolly = res.winningJolly;
        superstar = res.winningSuperstar;
        drawn = res.drawn;
    }

    /// @dev Count how many numbers match between ticket and winning combo.
    function _countMatches(
        uint8[6] memory a,
        uint8[6] memory b
    ) internal pure returns (uint8 m) {
        for (uint8 i = 0; i < NUMBERS_PER_TICKET; i++) {
            for (uint8 j = 0; j < NUMBERS_PER_TICKET; j++) {
                if (a[i] == b[j]) {
                    m++;
                    break;
                }
            }
        }
    }

    function _validateNumbers(uint8[6] calldata nums) internal pure {
        for (uint8 i = 0; i < NUMBERS_PER_TICKET; i++) {
            require(
                nums[i] >= 1 && nums[i] <= MAX_NUMBER,
                "Number out of range"
            );
            for (uint8 j = i + 1; j < NUMBERS_PER_TICKET; j++) {
                require(nums[i] != nums[j], "Duplicate number");
            }
        }
    }

    function _validateSingle(uint8 n) internal pure {
        require(n >= 1 && n <= MAX_NUMBER, "Number out of range");
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

    /// @notice Recover any ERC20 mistakenly sent (NOT USDC jackpot logic).
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "Zero address");
        IERC20(token).transfer(to, amount);
    }
}
