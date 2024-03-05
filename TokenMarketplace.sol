// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract TokenMarketplace is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {

    uint256 public constant PRICE_MULTIPLIER = 10**18;
    uint256 public feePercent;

    struct SellOrder {
        address seller;
        uint256 totalAmount;
        uint256 totalPrice; 
        uint256 amount;
        uint256 price; 
        bool isActive;
        address tokenAddress;
    }

    struct BuyOrder {
        uint256 totalAmount;
        uint256 totalPrice; 
        address buyer;
        uint256 amount;
        uint256 price; 
        bool isActive;
        address tokenAddress;
    }

    SellOrder[] public sellOrders;
    BuyOrder[] public buyOrders;
    mapping(address => bool) public tokenListed;

    event SellOrderCreated(uint256 indexed orderId, address indexed seller, uint256 totalAmount, uint256 totalPrice, uint256 amount, uint256 price, address tokenAddress);
    event BuyOrderCreated(uint256 indexed orderId, address indexed buyer, uint256 totalAmount, uint256 totalPrice, uint256 amount, uint256 price, address tokenAddress);
    event OrderCancelled(uint256 indexed orderId, bool isSellOrder);
    event OrderFulfilled(uint256 indexed orderId, bool isSellOrder, address counterparty, uint256 amount);
    event OrderPartiallyFulfilled(uint256 indexed orderId, bool isSellOrder, address counterparty, uint256 amount);

    function initialize(uint256 _initialFeePercent) public initializer {
    OwnableUpgradeable.__Ownable_init(msg.sender);
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
    require(_initialFeePercent <= 1000, "Fee cannot exceed 100%");
    feePercent = _initialFeePercent;
}

    function setFeePercent(uint256 _newFeePercent) external onlyOwner {
        require(_newFeePercent <= 1000, "Fee cannot exceed 100%");
        feePercent = _newFeePercent;
    }

    function listToken(address tokenAddress) public onlyOwner {
        require(tokenAddress != address(0), "Invalid token address");
        require(!tokenListed[tokenAddress], "Token already listed");
        tokenListed[tokenAddress] = true;
    }

    function delistToken(address tokenAddress) public onlyOwner {
        require(tokenListed[tokenAddress], "Token not listed");
        tokenListed[tokenAddress] = false;
    }

    function createSellOrder(address tokenAddress, uint256 amount, uint256 totalPrice) public nonReentrant {
        require(tokenListed[tokenAddress], "Token not listed");
        require(amount > 0 && totalPrice > 0, "Invalid amount or price");
        
        IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        sellOrders.push(SellOrder({
            seller: msg.sender,
            totalAmount: amount,
            totalPrice: totalPrice,
            amount: amount,
            price: totalPrice,
            isActive: true,
            tokenAddress: tokenAddress
        }));
        
        emit SellOrderCreated(sellOrders.length - 1, msg.sender, amount, totalPrice, amount, totalPrice, tokenAddress);
    }

    function createBuyOrder(address tokenAddress, uint256 amount, uint256 totalPrice) public payable nonReentrant {
        require(tokenListed[tokenAddress], "Token not listed");
        require(amount > 0 && totalPrice > 0, "Invalid amount or price");
        require(msg.value == totalPrice, "Incorrect ETH amount");

        buyOrders.push(BuyOrder({
            buyer: msg.sender,
            totalAmount: amount,
            totalPrice: totalPrice,
            amount: amount,
            price: totalPrice,
            isActive: true,
            tokenAddress: tokenAddress
        }));

        emit BuyOrderCreated(buyOrders.length - 1, msg.sender, amount, totalPrice, amount, totalPrice, tokenAddress);
    }


    function acceptSellOrder(uint256 orderId, uint256 amountToBuy) public payable nonReentrant {
    require(orderId < sellOrders.length, "Invalid order ID");
    SellOrder storage order = sellOrders[orderId];
    require(tokenListed[order.tokenAddress], "Token not listed");
    require(order.isActive, "Order is not active");
    require(amountToBuy <= order.amount, "Amount exceeds order availability");

    uint256 totalCostPerToken = order.totalPrice * PRICE_MULTIPLIER / order.totalAmount;
    uint256 totalCost = totalCostPerToken * amountToBuy / PRICE_MULTIPLIER;
    uint256 feeAmount = totalCost * feePercent / 1000; // Calculate 0.5% fee
    uint256 sellerPayment = totalCost - feeAmount; // Subtract fee from total payment to seller
    require(msg.value == totalCost, "Incorrect ETH amount");

    order.amount -= amountToBuy;
    order.price -= totalCost;

    require(IERC20Upgradeable(order.tokenAddress).transfer(msg.sender, amountToBuy), "Transfer failed");
    payable(order.seller).transfer(sellerPayment);
    payable(owner()).transfer(feeAmount); // Transfer fee to owner

    if (order.amount == 0) {
        order.isActive = false;
        emit OrderFulfilled(orderId, true, msg.sender, amountToBuy); // 完全履行
    } else {
        emit OrderPartiallyFulfilled(orderId, true, msg.sender, amountToBuy); // 部分履行
    }
}


   function acceptBuyOrder(uint256 orderId, uint256 amountToSell) public nonReentrant {
    require(orderId < buyOrders.length, "Invalid order ID");
    BuyOrder storage order = buyOrders[orderId];
    require(tokenListed[order.tokenAddress], "Token not listed");
    require(order.isActive, "Order is not active");
    require(amountToSell <= order.amount, "Amount exceeds order availability");

    uint256 totalCostPerToken = order.totalPrice * PRICE_MULTIPLIER / order.totalAmount;
    uint256 totalCost = totalCostPerToken * amountToSell / PRICE_MULTIPLIER;
    uint256 feeAmount = totalCost * feePercent / 1000; // Calculate 0.5% fee
    uint256 sellerPayment = totalCost - feeAmount; // Subtract fee from total payment to seller

    order.amount -= amountToSell;
    order.price -= totalCost;

    require(IERC20Upgradeable(order.tokenAddress).transferFrom(msg.sender, order.buyer, amountToSell), "Transfer failed");
    payable(msg.sender).transfer(sellerPayment);
    payable(owner()).transfer(feeAmount); // Transfer fee to owner


    if (order.amount == 0) {
        order.isActive = false;
        emit OrderFulfilled(orderId, false, order.buyer, amountToSell); // 完全履行
    } else {
        emit OrderPartiallyFulfilled(orderId, false, order.buyer, amountToSell); // 部分履行
    }
}

    function cancelSellOrder(uint256 orderId) public nonReentrant {
        require(orderId < sellOrders.length, "Invalid order ID");
        SellOrder storage order = sellOrders[orderId];
        require(order.seller == msg.sender, "Not the seller");
        require(order.isActive, "Order is not active");

        require(IERC20Upgradeable(order.tokenAddress).transfer(msg.sender, order.amount), "Token return failed");

        order.isActive = false;
        emit OrderCancelled(orderId, true);
    }

    function cancelBuyOrder(uint256 orderId) public nonReentrant {
        require(orderId < buyOrders.length, "Invalid order ID");
        BuyOrder storage order = buyOrders[orderId];
        require(order.buyer == msg.sender, "Not the buyer");
        require(order.isActive, "Order is not active");

        payable(msg.sender).transfer(order.price);

        order.isActive = false;
        emit OrderCancelled(orderId, false);
    }

    function getSellOrdersCount() public view returns (uint256) {
    return sellOrders.length;
    }

    function getBuyOrdersCount() public view returns (uint256) {
    return buyOrders.length;
    }


    function withdrawToken(address tokenAddress) public onlyOwner {
    IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
    uint256 contractTokenBalance = token.balanceOf(address(this));
    require(contractTokenBalance > 0, "The contract has no token balance");
    require(token.transfer(msg.sender, contractTokenBalance), "Transfer failed");
    }


    function withdrawETH() public onlyOwner {
    uint256 contractETHBalance = address(this).balance;
    require(contractETHBalance > 0, "The contract has no ETH balance");
    payable(msg.sender).transfer(contractETHBalance);
    }
}
