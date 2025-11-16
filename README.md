# 🎲 LuckyChain – Your Lucky Moment, Secured by Blockchain CURRENTLY WORKING ONLY BASE SEPOLIA . REQUEST USDC FROM CIRCLE FAUCET ON BASE SEPOLIA https://faucet.circle.com/
DAPP https://mikeminer.github.io/LuckyChain/

LuckyChain is an **on-chain 6/90 lottery** inspired by the Italian SuperEnalotto, rebuilt natively for **EVM chains** using:

- **USDC** as the ticket currency (1 USDC per ticket)  
- **Chainlink VRF v2.5** for **provably fair randomness**  
- **Fully on-chain jackpot logic** with rollover when nobody hits 6/6  

Supported networks (single codebase, 4 deployments):

- **Base Mainnet**
- **Base Sepolia** (testnet)
- **Optimism Mainnet**
- **Optimism Sepolia** (testnet)

The frontend is a **single-page dApp** (`index.html`) using **ethers.js** and MetaMask-compatible wallets, with a neon / glassmorphism UI.

---

## ✨ Core Idea

- Each **ticket**:  
  - 6 distinct numbers, from **1 to 90**  
  - 1 **Jolly** number (1–90)  
  - 1 **Superstar** number (1–90)  

- **Price per ticket**: `1.000000 USDC` (6 decimals)  

- Every **round**:
  - Maximum of **100 tickets**  
  - When the **100th ticket** is bought:
    - Contract requests randomness via **Chainlink VRF v2.5**
    - Draws:
      - **6 winning numbers**
      - **1 Jolly**
      - **1 Superstar**
    - Finds all tickets with **exactly 6/6 matches**
    - Splits the **entire jackpot** equally among all 6/6 winners
    - If **no 6/6 winner**, jackpot **rolls over** to the next round

There is **no central server**: logic is entirely implemented within the smart contracts.

