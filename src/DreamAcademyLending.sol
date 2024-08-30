// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract DreamAcademyLending {
    IPriceOracle public priceOracle;
    address public stableCoin;
    uint256 public reserve; // Track the reserve in ETH
    uint256 public totalSupply;
    uint256 public totalBorrows;
    uint256 public constant LIQUIDATION_THRESHOLD = 75; // 75%
    uint256 public constant LIQUIDATION_BONUS = 110; // 10% bonus for liquidators

    // 블록당 이자율을 계산한 상수
    uint256 public constant BLOCK_INTEREST_RATE = 1000000000000000000 + ((1000000000000000000 * 1) / 7200000); // 블록당 0.1% 복리 이자율 / 7200

    struct Account {
        uint256 collateralETH;
        uint256 debt;
        uint256 lastUpdate;
        uint256 suppliedERC20; // Track supplied ERC20 for interest calculation
    }

    mapping(address => Account) public accounts;

    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event Withdraw(address indexed user, address indexed asset, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed user, uint256 repayAmount);

    constructor(IPriceOracle _priceOracle, address _stableCoin) {
        priceOracle = _priceOracle;
        stableCoin = _stableCoin;
    }

    // Modifier to ensure account updates for interest calculations
    modifier updateAccount(address user) {
        if (accounts[user].lastUpdate > 0) {
            accounts[user].suppliedERC20 += pendingInterest(user);
        }
        accounts[user].lastUpdate = block.number; // 블록 단위로 변경
        _;
    }

    // Initialize the lending protocol with a reserve, should be exactly 1 wei
    function initializeLendingProtocol(address token) external payable {
        require(msg.value == 1, "Initial reserve must be 1");
        require(reserve == 0, "Protocol already initialized");
        reserve = msg.value; // Set the reserve to the amount of ether sent
        if (token != address(0)) {
            require(ERC20(token).transferFrom(msg.sender, address(this), msg.value));
        }
    }

    // Deposit function for ETH or ERC20 tokens
    function deposit(address asset, uint256 amount) external payable updateAccount(msg.sender) {
        require(amount > 0, "Amount must be greater than 0");

        if (asset == address(0)) {
            require(msg.value == amount, "Ether amount mismatch");
            accounts[msg.sender].collateralETH += amount;
        } else if (asset == stableCoin) {
            require(msg.value == 0, "Ether not needed for ERC20 deposit");
            ERC20(asset).transferFrom(msg.sender, address(this), amount);
            accounts[msg.sender].suppliedERC20 += amount; // Track supplied ERC20
        } else {
            revert("Unsupported asset");
        }

        emit Deposit(msg.sender, asset, amount);
    }

    // Ensure correct collateral checks for withdrawals
    function withdraw(address asset, uint256 amount) external updateAccount(msg.sender) {
        require(amount > 0, "Amount must be greater than 0");

        if (asset == address(0)) {
            require(accounts[msg.sender].collateralETH >= amount, "Insufficient ETH collateral");
            require(isWithdrawAllowed(msg.sender, amount, true), "Withdraw exceeds collateral");
            accounts[msg.sender].collateralETH -= amount;
            payable(msg.sender).transfer(amount);
        } else if (asset == stableCoin) {
            require(accounts[msg.sender].suppliedERC20 >= amount, "Insufficient ERC20 collateral");
            require(isWithdrawAllowed(msg.sender, amount, false), "Withdraw exceeds collateral");
            accounts[msg.sender].suppliedERC20 -= amount;
            ERC20(asset).transfer(msg.sender, amount);
        } else {
            revert("Unsupported asset");
        }

        emit Withdraw(msg.sender, asset, amount);
    }

    // Check collateral adequacy when borrowing
    function borrow(address asset, uint256 amount) external updateAccount(msg.sender) {
        require(asset == stableCoin, "Unsupported asset for borrowing");
        require(amount > 0, "Amount must be greater than 0");

        // Fetch collateral values in USD equivalent using price oracle
        uint256 collateralValueETH = (accounts[msg.sender].collateralETH * priceOracle.getPrice(address(0))) / 1e18;

        // Calculate current debt in USD equivalent
        uint256 currentDebtUSD = (accounts[msg.sender].debt * priceOracle.getPrice(stableCoin)) / 1e18;

        // Calculate the new total debt in USD equivalent after adding the borrow amount
        uint256 newTotalDebtUSD = currentDebtUSD + ((amount * priceOracle.getPrice(stableCoin)) / 1e18);

        // Ensure the collateral value is at least 150% of the new total debt value (66.66% LTV)
        require(collateralValueETH * 100 > newTotalDebtUSD * 150, "Insufficient collateral for borrowing");

        // Update debt and perform the transfer
        accounts[msg.sender].debt += amount;
        totalBorrows += amount;
        ERC20(asset).transfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    // Repay function for ERC20 tokens
    function repay(address asset, uint256 amount) external updateAccount(msg.sender) {
        require(asset == stableCoin, "Unsupported asset for repayment");
        require(amount > 0, "Amount must be greater than 0");
        require(accounts[msg.sender].debt >= amount, "Repayment exceeds debt");

        ERC20(asset).transferFrom(msg.sender, address(this), amount);
        accounts[msg.sender].debt -= amount;
        totalBorrows -= amount;

        emit Repay(msg.sender, amount);
    }

    // Correct liquidation checks and logic
    function liquidate(address user, address asset, uint256 amount) external {
        require(asset == stableCoin, "Unsupported asset for liquidation");
        require(amount > 0, "Amount must be greater than 0");

        uint256 collateralValueETH = accounts[user].collateralETH * priceOracle.getPrice(address(0)) / 1e18;
        uint256 debtValue = accounts[user].debt * priceOracle.getPrice(stableCoin) / 1e18;

        require(debtValue * 100 > collateralValueETH * 100 / LIQUIDATION_THRESHOLD, "Loan is healthy, cannot liquidate");

        uint256 repayAmount = amount > accounts[user].debt ? accounts[user].debt : amount;
        ERC20(asset).transferFrom(msg.sender, address(this), repayAmount);

        accounts[user].debt -= repayAmount;
        totalBorrows -= repayAmount;

        uint256 collateralToSeize = repayAmount * LIQUIDATION_BONUS / 100;
        if (accounts[user].collateralETH >= collateralToSeize) {
            accounts[user].collateralETH -= collateralToSeize;
            payable(msg.sender).transfer(collateralToSeize);
        } else {
            uint256 remainingSeize = collateralToSeize - accounts[user].collateralETH;
            accounts[user].collateralETH = 0;
            accounts[user].suppliedERC20 -= remainingSeize * 1e18 / priceOracle.getPrice(stableCoin);
            ERC20(stableCoin).transfer(msg.sender, remainingSeize);
        }

        emit Liquidate(msg.sender, user, repayAmount);
    }

    // Helper function to calculate pending interest
    function pendingInterest(address user) public view returns (uint256) {
        if (accounts[user].lastUpdate == 0) return 0; // Avoid division by zero

        uint256 blocksElapsed = block.number - accounts[user].lastUpdate;
        uint256 interest = accounts[user].suppliedERC20;

        // 복리 계산
        for (uint256 i = 0; i < blocksElapsed; i++) {
            interest = interest * BLOCK_INTEREST_RATE / 1e18;
        }

        return interest - accounts[user].suppliedERC20;
    }

    // Check if withdraw is allowed based on collateral and debt
    function isWithdrawAllowed(address user, uint256 withdrawAmount, bool isETH) public view returns (bool) {
        uint256 collateralValueETH = (accounts[user].collateralETH - (isETH ? withdrawAmount : 0)) * priceOracle.getPrice(address(0)) / 1e18;
        uint256 debtValue = accounts[user].debt * priceOracle.getPrice(stableCoin) / 1e18;

        return debtValue * 100 <= collateralValueETH * 100 / LIQUIDATION_THRESHOLD;
    }

    // Check for correct interest accrual and withdrawal
    function getAccruedSupplyAmount(address token) external view returns (uint256) {
        if (token == stableCoin) {
            return accounts[msg.sender].suppliedERC20 + pendingInterest(msg.sender);
        } else {
            return 0; // Unsupported token for this calculation
        }
    }
}

