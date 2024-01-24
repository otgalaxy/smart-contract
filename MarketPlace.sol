// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Ownable {
    address private _owner;

    constructor() {
        _owner = msg.sender;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(isOwner(), "Function accessible only by the owner !!");
        _;
    }

    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        _owner = _newOwner;
    }
}

contract OtGalaxyMarketPlaceV1 is Ownable, ReentrancyGuard {
    enum OrderState {
        Open,
        Fulfilled,
        Settled
    }

    struct Fill {
        address fulfiller;
        uint256 tokensReceived;
        uint256 ethFulfilled;
        uint256 pricePerToken;
    }

    struct Withdrawal {
        uint256 withdrawAmount;
        uint256 feeAmount;
        uint256 refundedTokens;
    }

    struct Order {
        address requester;
        address whitelistedAddress;
        address tokenAddress;
        uint256 initialTokens;
        uint256 availableTokens;
        uint256 requestedETH;
        uint256 fulfilledETH;
        uint256 pricePerToken;
        bool partiallyFillable;
        OrderState state;
    }

    mapping(bytes32 => Order) public orders;
    uint256 public orderCounter;
    address public devWallet;
    uint256 public nonHolderFee = 100; // 1%
    uint256 public HolderFee = 10; // 0.3%
    uint256 public holdingThresold;
    bool public isPaused = false;
    ERC20 public GalaxyToken;

    constructor(address _tokenAddress) {
        devWallet = msg.sender;
        GalaxyToken = ERC20(_tokenAddress);
    }

    modifier ContractNotPaused() {
        require(!isPaused, "Contract is paused");
        _;
    }

    function CreateOrder(
        address tokenAddress,
        uint256 requesterTokenAmount,
        uint256 requestedETHAmount,
        bool partiallyFillable,
        address whitelistedAddress
    ) external nonReentrant ContractNotPaused {
        require(
            requestedETHAmount > 0,
            "Requested ETH amount must be greater than 0"
        );
        require(
            requesterTokenAmount > 0,
            "Token amount must be greater than 0"
        );

        bytes32 orderId = keccak256(abi.encodePacked("Galaxy", ++orderCounter));

        Order storage order = orders[orderId];
        order.requester = msg.sender;
        order.tokenAddress = tokenAddress;
        order.partiallyFillable = partiallyFillable;
        order.whitelistedAddress = whitelistedAddress;
        order.state = OrderState.Open;

        // Get the initial token balance
        uint256 initialTokenBalance = IERC20(tokenAddress).balanceOf(
            address(this)
        );

        // Transfer tokens from the requester to the contract
        require(
            IERC20(tokenAddress).transferFrom(
                msg.sender,
                address(this),
                requesterTokenAmount
            ),
            "Token transfer failed"
        );

        // Calculate the actual tokens transferred (this pre and post check is to account for potential taxes in the erc20 token)
        uint256 afterTokenBalance = IERC20(tokenAddress).balanceOf(
            address(this)
        );
        uint256 transferredTokenAmount = afterTokenBalance -
            initialTokenBalance;

        uint8 tokenDecimals = ERC20(tokenAddress).decimals();

        // Calculate any fractional tokens and return them to the creator
        uint256 fractionalTokenAmount = transferredTokenAmount %
            10**tokenDecimals;
        uint256 wholeTokenAmount = transferredTokenAmount -
            fractionalTokenAmount;

        // Transfer fractional tokens back to the creator
        if (fractionalTokenAmount > 0) {
            require(
                IERC20(tokenAddress).transfer(
                    msg.sender,
                    fractionalTokenAmount
                ),
                "Fractional token transfer failed"
            );
        }

        // Update the order with the whole token amount
        order.initialTokens = wholeTokenAmount;
        order.availableTokens = wholeTokenAmount;

        uint256 netTransferPercent = (transferredTokenAmount * 10000) /
            requesterTokenAmount;
        uint256 transferTax = 10000 - netTransferPercent;
        emit TransferTaxRecorded(order.tokenAddress, transferTax);

        // Calculate the adjusted requestedETH by multiplying it by the net %
        order.requestedETH = transferTax > 0
            ? (requestedETHAmount * netTransferPercent) / 10000
            : requestedETHAmount;

        uint256 formattedTransferredTokenAmount = wholeTokenAmount /
            10**tokenDecimals;

        order.pricePerToken =
            order.requestedETH /
            formattedTransferredTokenAmount;

        emit OrderCreated(orders[orderId], orderId, tokenDecimals);
    }

    function placeOrder(bytes32 orderId, uint256 expectedPricePerToken)
        external
        payable
        nonReentrant
        ContractNotPaused
    {
        Order storage order = orders[orderId];
        require(order.requester != address(0), "Order doesn't exist");
        require(
            order.pricePerToken == expectedPricePerToken,
            "Price per token mismatch"
        );

        if (order.whitelistedAddress != address(0)) {
            require(msg.sender == order.whitelistedAddress, "Not authorized");
        }

        require(
            order.state == OrderState.Open,
            "Order already fulfilled or cancelled"
        );
        require(msg.value > 0, "ETH amount must be greater than 0");

        uint256 tokensToFulfill;
        if (order.partiallyFillable == false) {
            require(
                msg.value == order.requestedETH,
                "No partial fills permitted"
            );
            tokensToFulfill = order.availableTokens;
        } else {
            tokensToFulfill =
                (msg.value * 10**ERC20(order.tokenAddress).decimals()) /
                order.pricePerToken;
        }

        address tokenAddress = order.tokenAddress;

        require(tokensToFulfill > 0, "Token amount must be greater than 0");
        require(
            tokensToFulfill <= order.availableTokens,
            "Exceeds available tokens to fulfill"
        );

        order.availableTokens -= tokensToFulfill;
        order.fulfilledETH += msg.value;

        if (order.availableTokens == 0) {
            order.state = OrderState.Fulfilled;
        }

        require(
            IERC20(tokenAddress).transfer(msg.sender, tokensToFulfill),
            "Token transfer failed"
        );

        emit OrderFulfilled(
            orders[orderId],
            orderId,
            Fill(msg.sender, tokensToFulfill, msg.value, order.pricePerToken)
        );
    }

    function settleOrder(bytes32 orderId) external nonReentrant {
        Order storage order = orders[orderId];

        require(order.requester != address(0), "Order doesn't exist");
        require(order.requester == msg.sender, "Not authorized");
        require(order.state != OrderState.Settled, "Order already settled");

        order.state = OrderState.Settled;

        if (order.availableTokens > 0) {
            require(
                ERC20(order.tokenAddress).transfer(
                    order.requester,
                    order.availableTokens
                ),
                "Token transfer failed"
            );
        }

        uint256 transferredTokenAmount = order.availableTokens;
        order.availableTokens = 0;

        // Withdraw the fulfilled BNB
        uint256 fulfilledEth = order.fulfilledETH;
        uint256 withdrawAmount = 0;
        uint256 feeAmount = 0;

        if (fulfilledEth > 0) {
            // Deduct the fee from the fulfilled BNB
            uint256 feePercentage = GalaxyToken.balanceOf(order.requester) >=
                holdingThresold
                ? HolderFee
                : nonHolderFee;

            withdrawAmount = (fulfilledEth * (10000 - feePercentage)) / 10000;
            (bool success, ) = msg.sender.call{value: withdrawAmount}("");

            require(success, "Native Token transfer failed");

            feeAmount = fulfilledEth - withdrawAmount;
            (bool success3, ) = devWallet.call{value: feeAmount}("");
            require(success3, " DevWallet - Fee transfer failed");
        }

        emit OrderSettled(
            orders[orderId],
            orderId,
            Withdrawal(withdrawAmount, feeAmount, transferredTokenAmount)
        );
    }

    function changeOrderPrice(bytes32 orderId, uint256 newPrice) external {
        Order storage order = orders[orderId];

        require(order.requester != address(0), "Order doesn't exist");
        require(order.state == OrderState.Open, "Order cannot be updated");

        require(msg.sender == order.requester, "Not authorized");

        uint256 formattedAvailableTokens = order.availableTokens /
            10**ERC20(order.tokenAddress).decimals();

        if (order.partiallyFillable) {
            order.pricePerToken = newPrice;
            order.requestedETH =
                order.fulfilledETH +
                (formattedAvailableTokens * newPrice);
        } else {
            order.requestedETH = newPrice;
            order.pricePerToken = order.requestedETH / formattedAvailableTokens;
        }

        emit OrderPriceUpdated(order, orderId, newPrice);
    }

    function pauseContract() external onlyOwner {
        isPaused = true;
    }

    function unpauseContract() external onlyOwner {
        isPaused = false;
    }

    function changeDeveloperWallet(address _newDevWallet) external {
        require(msg.sender == devWallet, "Not authorized");
        devWallet = _newDevWallet;
    }

    event OrderCreated(
        Order order,
        bytes32 indexed orderId,
        uint8 tokenDecimals
    );

    event OrderPriceUpdated(
        Order order,
        bytes32 indexed orderId,
        uint256 newPrice
    );

    event OrderFulfilled(Order order, bytes32 indexed orderId, Fill fill);

    event OrderSettled(
        Order order,
        bytes32 indexed orderId,
        Withdrawal withdrawal
    );

    event TransferTaxRecorded(address tokenAddress, uint256 transferTax);
}
