// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
    LuckyChain – SuperEnalotto On-Chain
    Network: Optimism Mainnet (USDC + VRF v2.5)

    - Ticket cost: 1 USDC (6 decimals)
    - 6 numeri (1–90) + Jolly + Superstar
    - Estrazione dopo 100 ticket
*/

contract LuckyChainVRF_OptimismMainnet is VRFConsumerBaseV2 {
    // --------------------------------------------------
    // Constants
    // --------------------------------------------------
    uint256 public constant TICKET_PRICE = 1_000_000; // 1 USDC with 6 decimals
    uint8   public constant NUMBERS_PER_TICKET = 6;
    uint8   public constant MAX_NUMBER = 90;
    uint256 public constant TICKETS_PER_ROUND = 100;

    // --------------------------------------------------
    // Chainlink / Token
    // --------------------------------------------------
    IERC20 public usdc;
    VRFCoordinatorV2Interface public COORDINATOR;

    // --------------------------------------------------
    // Ownership
    // --------------------------------------------------
    address public owner;

    // --------------------------------------------------
    // Game state
    // --------------------------------------------------
    uint256 public jackpot;          // in USDC (6 decimals)
    uint256 public currentRound;     // round index (starts from 1)

    // round => number of tickets sold in that round
    mapping(uint256 => uint256) public ticketsPerRound;

    // Ticket info
    struct Ticket {
        address player;
        uint8[6] numbers;
        uint8 jolly;
        uint8 superstar;
        uint8 matches;
        bool  isWinner;
    }

    // round => ticketId => Ticket
    mapping(uint256 => mapping(uint256 => Ticket)) public tickets;

    // Last drawn combination (for the round being settled)
    uint8[6] public winningNumbers;
    uint8   public winningJolly;
    uint8   public winningSuperstar;
    bool    public roundFinished; // true when we've requested VRF and waiting

    // --------------------------------------------------
    // VRF config
    // --------------------------------------------------
    uint64  public subscriptionId;
    bytes32 public keyHash;
    uint32  public callbackGasLimit = 300000;
    uint16  public requestConfirmations = 3;

    // VRF requestId => round
    mapping(uint256 => uint256) public requestToRound;

    // --------------------------------------------------
    // Events
    // --------------------------------------------------
    event TicketBought(address indexed player, uint256 indexed round, uint256 ticketId);
    event DrawRequested(uint256 indexed requestId, uint256 indexed round);
    event DrawCompleted(
        uint8[6] winNums,
        uint8 jolly,
        uint8 superstar,
        uint256 indexed round
    );
    event JackpotPaid(uint256 indexed round, uint256 totalJackpot, uint256 winners);

    // --------------------------------------------------
    // Modifiers
    // --------------------------------------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // --------------------------------------------------
    // Constructor
    // --------------------------------------------------
    constructor(uint64 _subId)
        VRFConsumerBaseV2(
            0x5FE58960F730153eb5A84a47C51BD4E58302E1c8 // VRF Coordinator Optimism Mainnet
        )
    {
        owner = msg.sender;

        subscriptionId = _subId;

        // Optimism Mainnet – 30 gwei key hash
        keyHash = 0x8e7a847ba0757d1c302a3f0fde7b868ef8cf4acc32e48505f1a1d53693a10a19;

        // USDC on Optimism Mainnet (6 decimals)
        usdc = IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);

        COORDINATOR = VRFCoordinatorV2Interface(
            0x5FE58960F730153eb5A84a47C51BD4E58302E1c8
        );

        currentRound = 1;
    }

    // --------------------------------------------------
    // User: Buy Ticket
    // --------------------------------------------------
    function buyTicket(
        uint8[6] calldata nums,
        uint8 jolly,
        uint8 superstar
    ) external {
        require(!roundFinished, "Round closed");

        _validateNumbers(nums);
        _validateSingle(jolly);
        _validateSingle(superstar);

        // 1 USDC (6 decimals)
        require(
            usdc.transferFrom(msg.sender, address(this), TICKET_PRICE),
            "USDC transfer failed"
        );

        jackpot += TICKET_PRICE;

        // increase ticket count for this round
        ticketsPerRound[currentRound] += 1;
        uint256 ticketId = ticketsPerRound[currentRound];

        tickets[currentRound][ticketId] = Ticket({
            player: msg.sender,
            numbers: nums,
            jolly: jolly,
            superstar: superstar,
            matches: 0,
            isWinner: false
        });

        emit TicketBought(msg.sender, currentRound, ticketId);

        // trigger estrazione alla 100ª schedina
        if (ticketId == TICKETS_PER_ROUND) {
            _requestRandomWords();
        }
    }

    // --------------------------------------------------
    // Internal: Request VRF
    // --------------------------------------------------
    function _requestRandomWords() internal {
        uint256 reqId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            8 // 6 numeri + jolly + superstar
        );

        requestToRound[reqId] = currentRound;
        roundFinished = true;

        emit DrawRequested(reqId, currentRound);
    }

    // --------------------------------------------------
    // VRF Callback
    // --------------------------------------------------
    function fulfillRandomWords(
        uint256 reqId,
        uint256[] memory randomWords
    ) internal override {
        uint256 round = requestToRound[reqId];

        // 6 numeri vincenti 1–90
        for (uint8 i = 0; i < NUMBERS_PER_TICKET; i++) {
            winningNumbers[i] = uint8((randomWords[i] % MAX_NUMBER) + 1);
        }

        winningJolly     = uint8((randomWords[6] % MAX_NUMBER) + 1);
        winningSuperstar = uint8((randomWords[7] % MAX_NUMBER) + 1);

        emit DrawCompleted(
            winningNumbers,
            winningJolly,
            winningSuperstar,
            round
        );

        _evaluatePrizes(round);

        // prepara nuovo round
        currentRound++;
        roundFinished = false;
        // reset numeri vincenti per sicurezza
        for (uint8 i = 0; i < NUMBERS_PER_TICKET; i++) {
            winningNumbers[i] = 0;
        }
        winningJolly = 0;
        winningSuperstar = 0;
    }

    // --------------------------------------------------
    // Internal: Evaluate Prizes
    // --------------------------------------------------
    function _evaluatePrizes(uint256 round) internal {
        uint256 ticketCountRound = ticketsPerRound[round];
        if (ticketCountRound == 0) {
            emit JackpotPaid(round, 0, 0);
            return;
        }

        uint256 winners = 0;

        // 1) conta i 6/6
        for (uint256 i = 1; i <= ticketCountRound; i++) {
            Ticket storage t = tickets[round][i];
            if (t.player == address(0)) continue;

            uint8 matchCount = 0;
            for (uint8 x = 0; x < NUMBERS_PER_TICKET; x++) {
                for (uint8 y = 0; y < NUMBERS_PER_TICKET; y++) {
                    if (t.numbers[x] == winningNumbers[y]) {
                        matchCount++;
                    }
                }
            }

            t.matches = matchCount;

            if (matchCount == NUMBERS_PER_TICKET) {
                t.isWinner = true;
                winners++;
            }
        }

        if (winners == 0) {
            // nessun 6 → jackpot rimane per il prossimo round (rollover)
            emit JackpotPaid(round, 0, 0);
            return;
        }

        uint256 totalJackpot = jackpot;
        uint256 share = totalJackpot / winners;

        // 2) paga ogni vincitore
        for (uint256 i = 1; i <= ticketCountRound; i++) {
            Ticket storage t = tickets[round][i];
            if (t.isWinner) {
                usdc.transfer(t.player, share);
            }
        }

        jackpot = 0;
        emit JackpotPaid(round, totalJackpot, winners);
    }

    // --------------------------------------------------
    // Internal helpers: validation
    // --------------------------------------------------
    function _validateNumbers(uint8[6] memory nums) internal pure {
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

    // --------------------------------------------------
    // Admin utilities
    // --------------------------------------------------
    function setCallbackGasLimit(uint32 _limit) external onlyOwner {
        callbackGasLimit = _limit;
    }

    function setRequestConfirmations(uint16 _conf) external onlyOwner {
        requestConfirmations = _conf;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    /// @notice Recover any ERC20 mistakenly sent (NON per rubare il jackpot).
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "Zero address");
        IERC20(token).transfer(to, amount);
    }
}
