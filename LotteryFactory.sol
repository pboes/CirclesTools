// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/* ========== INTERFACES ========== */

interface IERC1155Receiver {
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4);

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
}

interface IERC1155 {
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IHub {
    function registerOrganization(string calldata _name, bytes32 _metadataDigest) external;
    function trust(address _trustReceiver, uint96 _expiry) external;
    function isTrusted(address _truster, address _trustee) external view returns (bool);
    function isHuman(address _address) external view returns (bool);
}

/* ========== MAIN CONTRACT ========== */

/**
 * @title LotteryContract
 * @notice A contract that:
 *  - Registers as an org via a Hub
 *  - Accepts CRC tokens as lottery tickets
 *  - Distributes prize tokens to winners
 *  - Allows only trusted members to participate if specified
 */
contract LotteryContract is IERC1155Receiver {
    // ---------- State Variables ----------

    address public owner;
    address public hubAddress;
    bool public isRegistered;
    address public trustedAddress;
    uint256 public acceptedId;

    // Lottery parameters
    string public lotteryName;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public ticketPrice;
    address public requireTrustedBy;
    address public prizeToken;
    uint256 public prizeAmount;
    bool public isCancelled;

    // Lottery state
    address[] public participants;
    mapping(address => uint256) public ticketsBought;
    bool public isDrawn;
    address public winner;
    uint256 public totalTicketsSold;

    // Add mapping for one ticket per address
    mapping(address => bool) public hasBought;

    // ---------- Events ----------

    event TicketBought(address indexed buyer, uint256 amount);
    event WinnerDrawn(address indexed winner, uint256 prizeAmount);
    event PrizePaid(address indexed winner, uint256 amount);
    event CRCRefunded(address indexed user, uint256 id, uint256 value, string reason);
    event CRCPaidToCreator(address indexed creator, uint256 amount);
    event LotteryCancelled(address indexed creator, uint256 refundAmount);
    event RemainderClaimed(address indexed owner, uint256 amount);

    // ---------- Constructor ----------

    constructor(
        address _hubAddress,
        string memory _lotteryName,
        address _trustedAddress,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _ticketPrice,
        address _requireTrustedBy,
        address _prizeToken,
        uint256 _prizeAmount,
        address _owner
    ) {
        owner = _owner;
        hubAddress = _hubAddress;
        lotteryName = _lotteryName;
        trustedAddress = _trustedAddress;
        startTime = _startTime == 0 ? block.timestamp : _startTime;
        endTime = _endTime;
        ticketPrice = _ticketPrice;
        requireTrustedBy = _requireTrustedBy;
        prizeToken = _prizeToken;
        prizeAmount = _prizeAmount;

        // Register as org and set up trust
        IHub(hubAddress).registerOrganization(_lotteryName, 0);
        isRegistered = true;

        // Set trust with 100 year expiry
        uint96 bigExpiry = uint96(block.timestamp + (100 * 365 days));
        IHub(hubAddress).trust(_trustedAddress, bigExpiry);
        
        // Derive the accepted token ID
        acceptedId = uint256(uint160(_trustedAddress));
    }

    // ---------- Modifiers ----------

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier lotteryActive() {
        require(!isCancelled, "Lottery cancelled");
        require(block.timestamp >= startTime, "Lottery not started");
        require(block.timestamp <= endTime, "Lottery ended");
        require(!isDrawn, "Lottery already drawn");
        _;
    }

    // ---------- Lottery Functions ----------

    function drawWinner() external onlyOwner {
        require(!isCancelled, "Lottery cancelled");
        require(block.timestamp > endTime, "Lottery not ended");
        require(!isDrawn, "Winner already drawn");
        require(participants.length > 0, "No participants");
        require(IERC20(prizeToken).balanceOf(address(this)) >= prizeAmount, "Not enough prize tokens");

        // Simple random selection (Note: This is not cryptographically secure)
        uint256 winnerIndex = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.difficulty,
            participants.length
        ))) % participants.length;

        winner = participants[winnerIndex];
        isDrawn = true;

        // Directly send prize to winner
        require(IERC20(prizeToken).transfer(winner, prizeAmount), "Prize transfer failed");

        emit WinnerDrawn(winner, prizeAmount);
        emit PrizePaid(winner, prizeAmount);
    }

    function cancelLottery() external onlyOwner {
        require(!isDrawn, "Winner already drawn");
        require(!isCancelled, "Already cancelled");
        require(block.timestamp <= endTime, "Lottery already ended");

        isCancelled = true;
        uint256 refundAmount = IERC20(prizeToken).balanceOf(address(this));
        if (refundAmount > 0) {
            require(IERC20(prizeToken).transfer(owner, refundAmount), "Refund failed");
        }
        emit LotteryCancelled(owner, refundAmount);
    }

    // ---------- View Functions ----------

    function hasParticipated(address user) external view returns (bool) {
        return ticketsBought[user] > 0;
    }

    function getTotalTicketsSold() external view returns (uint256) {
        return totalTicketsSold;
    }

    function getParticipantCount() external view returns (uint256) {
        return participants.length;
    }

    // ---------- ERC1155 Receiving ----------

    function onERC1155Received(
        address /*operator*/,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata /*data*/
    ) external override returns (bytes4) {
        require(msg.sender == hubAddress, "Not from Hub");
        require(id == acceptedId, "Wrong token ID");
        require(IHub(hubAddress).isHuman(from), "Not a registered human");
        require(!hasBought[from], "Already bought ticket");

        // If after endTime, refund and trigger draw/payout if needed
        if (block.timestamp > endTime) {
            IERC1155(msg.sender).safeTransferFrom(address(this), from, id, value, "");
            emit CRCRefunded(from, id, value, "Lottery ended; CRC refunded");
            // If not drawn and there are participants, trigger draw and payout
            if (!isDrawn && participants.length > 0) {
                _drawAndPayout();
            }
            // If not drawn and no participants, allow claimRemainder (owner can call)
            return this.onERC1155Received.selector;
        }
        // Refund if not funded
        if (IERC20(prizeToken).balanceOf(address(this)) < prizeAmount) {
            IERC1155(msg.sender).safeTransferFrom(address(this), from, id, value, "");
            emit CRCRefunded(from, id, value, "Lottery not funded");
            return this.onERC1155Received.selector;
        }
        // Refund if sent too little
        if (value < ticketPrice) {
            IERC1155(msg.sender).safeTransferFrom(address(this), from, id, value, "");
            emit CRCRefunded(from, id, value, "Sent too little");
            return this.onERC1155Received.selector;
        }
        // Refund remainder if sent too much
        uint256 refund = value > ticketPrice ? value - ticketPrice : 0;
        if (refund > 0) {
            IERC1155(msg.sender).safeTransferFrom(address(this), from, id, refund, "");
            emit CRCRefunded(from, id, refund, "Refund remainder");
        }
        _processTicketPurchase(from, ticketPrice);
        hasBought[from] = true;
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address /*operator*/,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata /*data*/
    ) external override returns (bytes4) {
        require(msg.sender == hubAddress, "Not from Hub");
        require(IHub(hubAddress).isHuman(from), "Not a registered human");
        require(!hasBought[from], "Already bought ticket");
        uint256 total = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            require(ids[i] == acceptedId, "Wrong token ID in batch");
            total += values[i];
        }
        // If after endTime, refund and trigger draw/payout if needed
        if (block.timestamp > endTime) {
            for (uint256 i = 0; i < ids.length; i++) {
                IERC1155(msg.sender).safeTransferFrom(address(this), from, ids[i], values[i], "");
                emit CRCRefunded(from, ids[i], values[i], "Lottery ended; CRC refunded");
            }
            if (!isDrawn && participants.length > 0) {
                _drawAndPayout();
            }
            return this.onERC1155BatchReceived.selector;
        }
        // Refund if not funded
        if (IERC20(prizeToken).balanceOf(address(this)) < prizeAmount) {
            for (uint256 i = 0; i < ids.length; i++) {
                IERC1155(msg.sender).safeTransferFrom(address(this), from, ids[i], values[i], "");
                emit CRCRefunded(from, ids[i], values[i], "Lottery not funded");
            }
            return this.onERC1155BatchReceived.selector;
        }
        // Refund if sent too little
        if (total < ticketPrice) {
            for (uint256 i = 0; i < ids.length; i++) {
                IERC1155(msg.sender).safeTransferFrom(address(this), from, ids[i], values[i], "");
                emit CRCRefunded(from, ids[i], values[i], "Sent too little");
            }
            return this.onERC1155BatchReceived.selector;
        }
        // Refund remainder if sent too much
        uint256 refund = total > ticketPrice ? total - ticketPrice : 0;
        if (refund > 0) {
            IERC1155(msg.sender).safeTransferFrom(address(this), from, acceptedId, refund, "");
            emit CRCRefunded(from, acceptedId, refund, "Refund remainder");
        }
        _processTicketPurchase(from, ticketPrice);
        hasBought[from] = true;
        return this.onERC1155BatchReceived.selector;
    }

    // Internal: draw and payout logic
    function _drawAndPayout() internal {
        require(!isDrawn, "Already drawn");
        require(participants.length > 0, "No participants");
        require(IERC20(prizeToken).balanceOf(address(this)) >= prizeAmount, "Not enough prize tokens");
        uint256 winnerIndex = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.difficulty,
            participants.length
        ))) % participants.length;
        winner = participants[winnerIndex];
        isDrawn = true;
        require(IERC20(prizeToken).transfer(winner, prizeAmount), "Prize transfer failed");
        emit WinnerDrawn(winner, prizeAmount);
        emit PrizePaid(winner, prizeAmount);
        // After payout, if any tokens remain (e.g. overfunded), send to owner
        uint256 bal = IERC20(prizeToken).balanceOf(address(this));
        if (bal > 0) {
            IERC20(prizeToken).transfer(owner, bal);
            emit RemainderClaimed(owner, bal);
        }
    }

    // ---------- Internal Functions ----------

    function _canParticipate(address user) internal view returns (bool) {
        if (!isRegistered) return false;
        if (isCancelled) return false;
        if (block.timestamp < startTime) return false;
        if (block.timestamp > endTime) return false;
        if (isDrawn) return false;
        if (IERC20(prizeToken).balanceOf(address(this)) < prizeAmount) return false;

        if (requireTrustedBy != address(0)) {
            return IHub(hubAddress).isTrusted(requireTrustedBy, user);
        }
        return true;
    }

    function _processTicketPurchase(address buyer, uint256 amount) internal {
        uint256 tickets = amount / ticketPrice;
        if (tickets == 0) {
            IERC1155(hubAddress).safeTransferFrom(address(this), buyer, acceptedId, amount, "");
            emit CRCRefunded(buyer, acceptedId, amount, "Insufficient for ticket");
            return;
        }

        uint256 totalCost = tickets * ticketPrice;
        uint256 refund = amount - totalCost;

        if (refund > 0) {
            IERC1155(hubAddress).safeTransferFrom(address(this), buyer, acceptedId, refund, "");
        }

        // Forward CRC to creator
        IERC1155(hubAddress).safeTransferFrom(address(this), owner, acceptedId, totalCost, "");
        emit CRCPaidToCreator(owner, totalCost);

        if (ticketsBought[buyer] == 0) {
            participants.push(buyer);
        }
        ticketsBought[buyer] += tickets;
        totalTicketsSold += tickets;

        emit TicketBought(buyer, tickets);
    }

    // ---------- ERC165 ----------
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == 0x01ffc9a7;
    }

    // ---------- Owner can claim remaining prize tokens after lottery is over ----------
    function claimRemainder() external onlyOwner {
        require(isDrawn || isCancelled || block.timestamp > endTime, "Lottery not over");
        // Ensure that the prize has been paid out or the lottery was cancelled or had no participants
        require(isDrawn || isCancelled || participants.length == 0, "Prize not paid out");
        uint256 bal = IERC20(prizeToken).balanceOf(address(this));
        require(bal > 0, "No tokens left");
        IERC20(prizeToken).transfer(owner, bal);
        emit RemainderClaimed(owner, bal);
    }
}

/* ========== FACTORY ========== */

contract LotteryFactory {
    address public constant HARDCODED_HUB = 0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8;
    address[] private _allDeployed;
    address public factoryOwner;

    event LotteryCreated(address indexed lottery, address indexed creator, string name);

    constructor() {
        factoryOwner = msg.sender;
    }

    modifier onlyFactoryOwner() {
        require(msg.sender == factoryOwner, "Not factory owner");
        _;
    }

    function allDeployments() external view returns (address[] memory) {
        return _allDeployed;
    }

    function createLottery(
        string memory _lotteryName,
        address _trustedAddress,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _ticketPrice,
        address _requireTrustedBy,
        address _prizeToken,
        uint256 _prizeAmount
    ) public returns (address) {
        // Input validation
        require(bytes(_lotteryName).length > 0, "Empty lottery name");
        require(_trustedAddress != address(0), "Invalid trusted address");
        require(_endTime > _startTime, "End time must be after start time");
        require(_ticketPrice > 0, "Ticket price must be greater than 0");
        require(_prizeToken != address(0), "Invalid prize token address");
        require(_prizeAmount > 0, "Prize amount must be greater than 0");

        // Create new lottery
        LotteryContract lottery = new LotteryContract(
            HARDCODED_HUB,
            _lotteryName,
            _trustedAddress,
            _startTime,
            _endTime,
            _ticketPrice,
            _requireTrustedBy,
            _prizeToken,
            _prizeAmount,
            msg.sender  // Pass the creator as the owner
        );

        _allDeployed.push(address(lottery));
        emit LotteryCreated(address(lottery), msg.sender, _lotteryName);
        return address(lottery);
    }

    function createLotteryDefault() external returns (address) {
        return createLottery(
            "TestLottery",                                    // lotteryName
            0x1ACA75e38263c79d9D4F10dF0635cc6FCfe6F026,      // trustedAddr
            block.timestamp,                                  // startTime
            block.timestamp + 5 minutes,                      // endTime
            1e17,                                            // ticketPrice (0.1 CRC)
            address(0),                                      // requireTrustedBy (no trust required)
            0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0,      // prizeToken
            1e5                                              // prizeAmount
        );
    }

    // Function to transfer factory ownership
    function transferFactoryOwnership(address newOwner) external onlyFactoryOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        factoryOwner = newOwner;
    }
} 