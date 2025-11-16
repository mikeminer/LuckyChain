// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
    LuckyChain – SuperEnalotto On-Chain
    Network: Base Mainnet (USDC + VRF v2.5)

    - Ticket cost: 1 USDC (6 decimals)
    - 6 numeri (1–90) + Jolly + Superstar
    - Estrazione dopo 101 ticket (come nel tuo codice)
*/

contract LuckyChainVRF_BaseMainnet is VRFConsumerBaseV2 {
    IERC20 public usdc;
    VRFCoordinatorV2Interface public COORDINATOR;

    address public owner;

    uint256 public jackpot;      // in USDC (6 decimals)
    uint256 public ticketCount;  // ticket nel round corrente
    uint256 public currentRound;

    uint64  public subscriptionId;
    bytes32 public keyHash;
    uint32  public callbackGasLimit = 300000;
    uint16  public requestConfirmations = 3;

    struct Ticket {
        address player;
        uint8[6] numbers;
        uint8 jolly;
        uint8 superstar;
        bool claimed;
        uint8 matches;
        bool isWinner;
    }

    // round => ticketId => Ticket
    mapping(uint256 => mapping(uint256 => Ticket)) public tickets;

    uint8[6] public winningNumbers;
    uint8 public winningJolly;
    uint8 public winningSuperstar;
    bool  public roundFinished;

    // VRF requestId => round
    mapping(uint256 => uint256) public requestToRound;

    event TicketBought(address indexed player, uint256 round, uint256 ticketId);
    event DrawRequested(uint256 requestId, uint256 round);
    event DrawCompleted(
        uint8[6] winNums,
        uint8 jolly,
        uint8 superstar,
        uint256 round
    );
    event JackpotPaid(uint256 round, uint256 totalJackpot, uint256 winners);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint64 _subId)
        VRFConsumerBaseV2(
            0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634 // VRF Base Mainnet
        )
    {
        owner = msg.sender;

        subscriptionId = _subId;

        // Base mainnet – 30 gwei key hash
        keyHash = 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;

        // USDC on Base mainnet (6 decimals)
        usdc = IERC20(0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913);

        COORDINATOR = VRFCoordinatorV2Interface(
            0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634
        );

        currentRound = 1;
    }

    function buyTicket(
        uint8[6] calldata nums,
        uint8 jolly,
        uint8 superstar
    ) external {
        require(!roundFinished, "Round closed");

        // 1 USDC con 6 decimali
        require(usdc.transferFrom(msg.sender, address(this), 1e6), "USDC transfer failed");

        jackpot += 1e6;
        ticketCount++;

        tickets[currentRound][ticketCount] = Ticket(
            msg.sender,
            nums,
            jolly,
            superstar,
            false,
            0,
            false
        );

        emit TicketBought(msg.sender, currentRound, ticketCount);

        // nel tuo schema: estrazione alla 101ª schedina
        if (ticketCount == 101) {
            _requestRandomWords();
        }
    }

    function _requestRandomWords() internal {
        uint256 reqId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            8  // 6 numeri + jolly + superstar
        );

        requestToRound[reqId] = currentRound;

        roundFinished = true;
        emit DrawRequested(reqId, currentRound);
    }

    function fulfillRandomWords(
        uint256 reqId,
        uint256[] memory randomWords
    ) internal override {
        uint256 round = requestToRound[reqId];

        // 6 numeri vincenti 1–90
        for (uint8 i = 0; i < 6; i++) {
            winningNumbers[i] = uint8((randomWords[i] % 90) + 1);
        }

        winningJolly     = uint8((randomWords[6] % 90) + 1);
        winningSuperstar = uint8((randomWords[7] % 90) + 1);

        emit DrawCompleted(
            winningNumbers,
            winningJolly,
            winningSuperstar,
            round
        );

        _evaluatePrizes(round);

        // nuovo round
        currentRound++;
        ticketCount = 0;
        roundFinished = false;
        delete winningNumbers;
    }

    function _evaluatePrizes(uint256 round) internal {
        uint256 winners = 0;

        // 1) conta i vincitori con 6/6
        for (uint256 i = 1; i <= 101; i++) {
            Ticket storage t = tickets[round][i];
            if (t.player == address(0)) continue;

            uint8 matchCount = 0;
            for (uint8 x = 0; x < 6; x++) {
                for (uint8 y = 0; y < 6; y++) {
                    if (t.numbers[x] == winningNumbers[y]) {
                        matchCount++;
                    }
                }
            }

            t.matches = matchCount;

            if (matchCount == 6) {
                t.isWinner = true;
                winners++;
            }
        }

        if (winners == 0) {
            // nessun 6: jackpot rimane per il prossimo round (rollover)
            emit JackpotPaid(round, 0, 0);
            return;
        }

        uint256 totalJackpot = jackpot;
        uint256 share = totalJackpot / winners;

        // 2) paga ogni vincitore con la sua quota
        for (uint256 i = 1; i <= 101; i++) {
            Ticket storage t = tickets[round][i];
            if (t.isWinner) {
                usdc.transfer(t.player, share);
            }
        }

        jackpot = 0;
        emit JackpotPaid(round, totalJackpot, winners);
    }
}
