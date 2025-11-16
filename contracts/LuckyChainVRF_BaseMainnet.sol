// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
    LuckyChain – SuperEnalotto On-Chain
    Base Mainnet Version (USDC + VRF v2.5)
*/

contract LuckyChainVRF_BaseMainnet is VRFConsumerBaseV2 {
    IERC20 public usdc;

    VRFCoordinatorV2Interface COORDINATOR;

    address public owner;

    uint256 public jackpot;
    uint256 public ticketCount;

    uint64 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 300000;
    uint16 public requestConfirmations = 3;

    uint256 public currentRound;
    mapping(uint256 => mapping(uint256 => Ticket)) public tickets;

    struct Ticket {
        address player;
        uint8[6] numbers;
        uint8 jolly;
        uint8 superstar;
        bool claimed;
        uint8 matches;
        bool isWinner;
    }

    uint8[6] public winningNumbers;
    uint8 public winningJolly;
    uint8 public winningSuperstar;
    bool public roundFinished;

    mapping(uint256 => uint256) public requestToRound;

    event TicketBought(address indexed player, uint256 round, uint256 ticketId);
    event DrawRequested(uint256 requestId, uint256 round);
    event DrawCompleted(
        uint8[6] winNums,
        uint8 jolly,
        uint8 superstar,
        uint256 round
    );

    constructor(uint64 _subId)
        VRFConsumerBaseV2(
            0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634 // VRF Base Mainnet
        )
    {
        owner = msg.sender;

        subscriptionId = _subId;

        keyHash = 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;

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

        require(usdc.transferFrom(msg.sender, address(this), 1e6));

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
            8
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

        for (uint8 i = 0; i < 6; i++)
            winningNumbers[i] = uint8((randomWords[i] % 90) + 1);

        winningJolly = uint8((randomWords[6] % 90) + 1);
        winningSuperstar = uint8((randomWords[7] % 90) + 1);

        emit DrawCompleted(
            winningNumbers,
            winningJolly,
            winningSuperstar,
            round
        );

        _evaluatePrizes();

        currentRound++;
        ticketCount = 0;
        roundFinished = false;
        delete winningNumbers;
    }

    function _evaluatePrizes() internal {
        bool jackpotWon = false;

        for (uint256 i = 1; i <= 101; i++) {
            Ticket storage t = tickets[currentRound][i];
            if (t.player == address(0)) continue;

            uint8 matchCount = 0;
            for (uint8 x = 0; x < 6; x++)
                for (uint8 y = 0; y < 6; y++)
                    if (t.numbers[x] == winningNumbers[y]) matchCount++;

            t.matches = matchCount;

            if (matchCount == 6) {
                t.isWinner = true;
                jackpotWon = true;
            }
        }

        if (jackpotWon) {
            for (uint256 i = 1; i <= 101; i++) {
                if (tickets[currentRound][i].isWinner)
                    usdc.transfer(tickets[currentRound][i].player, jackpot);
            }
            jackpot = 0;
        }
    }
}
