// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract TokenMarketplace is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {

    uint256 public constant PRICE_MULTIPLIER = 10**8;
    uint256 public feePercent;

    struct SellOrder {
        address seller;
        uint256 totalAmount;
        uint256 totalPrice; 
        uint256 amount;
        uint256 price;
        uint256 unitPrice; 
        bool isActive;
        address tokenAddress;
    }

    struct BuyOrder {
        uint256 totalAmount;
        uint256 totalPrice; 
        address buyer;
        uint256 amount;
        uint256 price;
        uint256 unitPrice; 
        bool isActive;
        address tokenAddress;
    }

    SellOrder[] public sellOrders;
    BuyOrder[] public buyOrders;
    mapping(address => bool) public tokenListed;

    event SellOrderCreated(uint256 indexed orderId, address indexed seller, uint256 totalAmount, uint256 totalPrice, uint256 amount, uint256 unitPrice, address tokenAddress);
    event BuyOrderCreated(uint256 indexed orderId, address indexed buyer, uint256 totalAmount, uint256 totalPrice, uint256 amount, uint256 unitPrice, address tokenAddress);
    event OrderCancelled(uint256 indexed orderId, bool isSellOrder);
    event OrderFulfilled(uint256 indexed orderId, bool isSellOrder, address counterparty, uint256 amount);
    event OrderPartiallyFulfilled(uint256 indexed orderId, bool isSellOrder, address counterparty, uint256 amount);

    uint256 public maxbatchsize;

    function initialize(uint256 _initialFeePercent) public initializer {
    OwnableUpgradeable.__Ownable_init(msg.sender);
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
    require(_initialFeePercent <= 1000, "Fee cannot exceed 100%");
    feePercent = _initialFeePercent;
    // maxbatchsize = 10;
}

    function setFeePercent(uint256 _newFeePercent) external onlyOwner {
        require(_newFeePercent <= 1000, "Fee cannot exceed 100%");
        feePercent = _newFeePercent;
    }

    function setMaxbatchsize(uint256 _maxbatchsize) external onlyOwner {
        require(_maxbatchsize <= 100, "Maxbatchsize is too big");
        maxbatchsize = _maxbatchsize;
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

    function createSellOrder(address tokenAddress, uint256 amount, uint256 unitPrice) public nonReentrant {
        require(tokenListed[tokenAddress], "Token not listed");
        require(amount >= PRICE_MULTIPLIER && unitPrice > 0, "Invalid amount or price");
        
        IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        uint256 totalPrice = unitPrice * amount / PRICE_MULTIPLIER;

        sellOrders.push(SellOrder({
            seller: msg.sender,
            totalAmount: amount / PRICE_MULTIPLIER,
            totalPrice: totalPrice,
            amount: amount / PRICE_MULTIPLIER,
            price: totalPrice,
            unitPrice: unitPrice,
            isActive: true,
            tokenAddress: tokenAddress
        }));
        
        emit SellOrderCreated(sellOrders.length - 1, msg.sender, amount, totalPrice, amount, unitPrice, tokenAddress);
    }

    function createBuyOrder(address tokenAddress, uint256 amount, uint256 unitPrice) public payable nonReentrant {
        require(tokenListed[tokenAddress], "Token not listed");
        require(amount >= PRICE_MULTIPLIER && unitPrice > 0, "Invalid amount or price");
        uint256 totalPrice = unitPrice * amount / PRICE_MULTIPLIER;
        require(msg.value == totalPrice, "Incorrect ETH amount");

        buyOrders.push(BuyOrder({
            buyer: msg.sender,
            totalAmount: amount / PRICE_MULTIPLIER,
            totalPrice: totalPrice,
            amount: amount / PRICE_MULTIPLIER,
            price: totalPrice,
            unitPrice: unitPrice,
            isActive: true,
            tokenAddress: tokenAddress
        }));

        emit BuyOrderCreated(buyOrders.length - 1, msg.sender, amount, totalPrice, amount, unitPrice, tokenAddress);
    }


    function acceptSellOrder(uint256 orderId, uint256 amountToBuy) public payable nonReentrant {
    require(orderId < sellOrders.length, "Invalid order ID");
    SellOrder storage order = sellOrders[orderId];
    require(tokenListed[order.tokenAddress], "Token not listed");
    require(order.isActive, "Order is not active");
    require(amountToBuy <= order.amount * PRICE_MULTIPLIER, "Amount exceeds order availability");

    // uint256 totalCostPerToken = order.totalPrice * PRICE_MULTIPLIER / order.totalAmount;
    uint256 totalCost = order.unitPrice * amountToBuy / PRICE_MULTIPLIER;
    uint256 feeAmount = totalCost * feePercent / 1000; // Calculate 0.5% fee
    uint256 sellerPayment = totalCost - feeAmount; // Subtract fee from total payment to seller
    require(msg.value >= totalCost, "Incorrect ETH amount");

    order.amount -= amountToBuy / PRICE_MULTIPLIER;
    order.price -= totalCost;

    require(IERC20Upgradeable(order.tokenAddress).transfer(msg.sender, amountToBuy), "Transfer failed");
    payable(order.seller).transfer(sellerPayment);
    payable(owner()).transfer(feeAmount); // Transfer fee to owner

    if (order.amount == 0) {
        order.isActive = false;
        emit OrderFulfilled(orderId, true, msg.sender, amountToBuy); 
    } else {
        emit OrderPartiallyFulfilled(orderId, true, msg.sender, amountToBuy); 
    }
}


function batchAcceptSellOrders(uint256[] calldata orderIds, uint256[] calldata amountsToBuy) public payable nonReentrant {
    require(orderIds.length == amountsToBuy.length, "Length mismatch");
    require(orderIds.length <= maxbatchsize, "Exceeds maximum batch size");

    uint256 totalEthAmount = 0; 

    for (uint256 i = 0; i < orderIds.length; i++) {
        require(orderIds[i] < sellOrders.length, "Invalid order ID");
        SellOrder storage order = sellOrders[orderIds[i]];
        require(tokenListed[order.tokenAddress], "Token not listed");
        require(order.isActive, "Order is not active");
        require(amountsToBuy[i] <= order.amount * PRICE_MULTIPLIER, "Amount exceeds order availability");

        // uint256 totalCostPerToken = order.totalPrice * PRICE_MULTIPLIER / order.totalAmount;
        uint256 totalCost = order.unitPrice * amountsToBuy[i] / PRICE_MULTIPLIER;
        totalEthAmount += totalCost; 

        uint256 feeAmount = totalCost * feePercent / 1000; // Calculate 0.5% fee
        uint256 sellerPayment = totalCost - feeAmount; // Subtract fee from total payment to seller
        require(msg.value >= totalCost, "Insufficient ETH amount");

        order.amount -= amountsToBuy[i] / PRICE_MULTIPLIER;
        order.price -= totalCost;

        require(IERC20Upgradeable(order.tokenAddress).transfer(msg.sender, amountsToBuy[i]), "Transfer failed");
        payable(order.seller).transfer(sellerPayment);
        payable(owner()).transfer(feeAmount); // Transfer fee to owner

        if (order.amount == 0) {
            order.isActive = false;
            emit OrderFulfilled(orderIds[i], true, msg.sender, amountsToBuy[i]); 
        } else {
            emit OrderPartiallyFulfilled(orderIds[i], true, msg.sender, amountsToBuy[i]); 
        }
    }

    require(msg.value >= totalEthAmount, "Incorrect ETH amount");
}


   function acceptBuyOrder(uint256 orderId, uint256 amountToSell) public nonReentrant {
    require(orderId < buyOrders.length, "Invalid order ID");
    BuyOrder storage order = buyOrders[orderId];
    require(tokenListed[order.tokenAddress], "Token not listed");
    require(order.isActive, "Order is not active");
    require(amountToSell <= order.amount * PRICE_MULTIPLIER, "Amount exceeds order availability");

    // uint256 totalCostPerToken = order.totalPrice * PRICE_MULTIPLIER / order.totalAmount;
    uint256 totalCost = order.unitPrice * amountToSell / PRICE_MULTIPLIER;
    uint256 feeAmount = totalCost * feePercent / 1000; // Calculate 0.5% fee
    uint256 sellerPayment = totalCost - feeAmount; // Subtract fee from total payment to seller

    order.amount -= amountToSell / PRICE_MULTIPLIER;
    order.price -= totalCost;

    require(IERC20Upgradeable(order.tokenAddress).transferFrom(msg.sender, order.buyer, amountToSell), "Transfer failed");
    payable(msg.sender).transfer(sellerPayment);
    payable(owner()).transfer(feeAmount); // Transfer fee to owner


    if (order.amount == 0) {
        order.isActive = false;
        emit OrderFulfilled(orderId, false, order.buyer, amountToSell); 
    } else {
        emit OrderPartiallyFulfilled(orderId, false, order.buyer, amountToSell); 
    }
}


 function batchAcceptBuyOrders(uint256[] calldata orderIds, uint256[] calldata amountsToSell) public {
    require(orderIds.length == amountsToSell.length, "Length mismatch");
    require(orderIds.length <= maxbatchsize, "Exceeds maximum batch size");

    for (uint256 i = 0; i < orderIds.length; i++) {
        acceptBuyOrder(orderIds[i], amountsToSell[i]);
    }
}

    function cancelSellOrder(uint256 orderId) public nonReentrant {
        require(orderId < sellOrders.length, "Invalid order ID");
        SellOrder storage order = sellOrders[orderId];
        require(order.seller == msg.sender, "Not the seller");
        require(order.isActive, "Order is not active");

        require(IERC20Upgradeable(order.tokenAddress).transfer(msg.sender, order.amount * PRICE_MULTIPLIER), "Token return failed");

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
