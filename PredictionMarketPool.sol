// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract PredictionMarketPool is Initializable, ReentrancyGuard {
    using Math for uint256;

    struct PoolOption {
        string description;
        address tokenAddress;
        uint256 reserve;
        uint256 weight;
    }

    // 状態変数
    address public factory;
    address public paymentToken;
    string public description;
    uint256 public endTime;
    uint256 public optionCount;
    bool public resolved;
    uint8 public winningOption;
    uint256 public totalLiquidity;
    bool public disputed;
    uint256 public resolutionThreshold;
    uint256 public feeRate;
    uint256 public constant PRECISION = 1e18;

    struct PoolState {
        bool isInitialized;
        bool isPaused;
        uint128 lastUpdateTimestamp;
        uint128 disputeEndTime;
    }
    PoolState public poolState;

    // マッピング
    mapping(uint256 => PoolOption) public options;
    mapping(address => mapping(uint256 => uint256)) public lpTokenBalances;
    mapping(address => mapping(uint256 => uint256)) public pendingTrades;
    mapping(address => uint256) public disputeVotes;

    // イベント
    event LiquidityAdded(address indexed provider, uint256[] amounts);
    event LiquidityRemoved(address indexed provider, uint256[] amounts);
    event OptionTraded(uint256 indexed optionId, address indexed trader, uint256 amount, bool isBuy);
    event PoolResolved(uint8 winningOption);
    event TradeQueued(address indexed trader, uint256 indexed optionId, uint256 amount);
    event BatchProcessed(uint256 timestamp, uint256 tradesProcessed);
    event DisputeVoteSubmitted(address indexed voter, uint256 amount);
    event DisputeResolved(bool upheld, uint8 newWinningOption);

    // モディファイア
    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory");
        _;
    }

    modifier notResolved() {
        require(!resolved, "Pool resolved");
        _;
    }

    modifier notDisputed() {
        require(!disputed, "Pool disputed");
        _;
    }

    modifier onlyDuringDisputePeriod() {
        require(block.timestamp <= poolState.disputeEndTime, "Dispute period ended");
        _;
    }

    /**
     * @notice プールの初期化
     */
    function initialize(
        address _factory,
        address _paymentToken,
        string memory _description,
        uint256 _endTime,
        uint256 _optionCount,
        uint256 _feeRate,
        uint256 _resolutionThreshold
    ) external initializer {
        require(_factory != address(0), "Invalid factory");
        require(_paymentToken != address(0), "Invalid payment token");
        require(_endTime > block.timestamp, "Invalid end time");
        require(_optionCount >= 2, "Min 2 options required");
        require(_feeRate <= 1000, "Fee too high"); // max 10%
        
        factory = _factory;
        paymentToken = _paymentToken;
        description = _description;
        endTime = _endTime;
        optionCount = _optionCount;
        feeRate = _feeRate;
        resolutionThreshold = _resolutionThreshold;
        poolState.isInitialized = true;
        poolState.lastUpdateTimestamp = uint128(block.timestamp);
    }

    /**
     * @notice 流動性の追加
     */
    function addLiquidity(uint256[] calldata amounts) external nonReentrant notResolved notDisputed {
        require(amounts.length == optionCount, "Invalid amounts length");
        require(block.timestamp < endTime, "Pool ended");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
            options[i].reserve += amounts[i];
            lpTokenBalances[msg.sender][i] += amounts[i];
        }

        require(IERC20(paymentToken).transferFrom(msg.sender, address(this), totalAmount), "Transfer failed");
        totalLiquidity += totalAmount;

        emit LiquidityAdded(msg.sender, amounts);
        poolState.lastUpdateTimestamp = uint128(block.timestamp);
    }

    /**
     * @notice 流動性の削除
     */
    function removeLiquidity(uint256[] calldata amounts) external nonReentrant {
        require(amounts.length == optionCount, "Invalid amounts length");
        require(resolved && !disputed, "Pool not ready");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] <= lpTokenBalances[msg.sender][i], "Insufficient balance");
            
            if (i == winningOption) {
                totalAmount += amounts[i];
            }
            
            lpTokenBalances[msg.sender][i] -= amounts[i];
            options[i].reserve -= amounts[i];
        }

        if (totalAmount > 0) {
            require(IERC20(paymentToken).transfer(msg.sender, totalAmount), "Transfer failed");
        }
        totalLiquidity -= totalAmount;

        emit LiquidityRemoved(msg.sender, amounts);
        poolState.lastUpdateTimestamp = uint128(block.timestamp);
    }

    /**
     * @notice 取引のキュー追加
     */
    function queueTrade(uint256 optionId, uint256 amount, bool isBuy) external notResolved notDisputed {
        require(optionId < optionCount, "Invalid option");
        require(block.timestamp < endTime, "Pool ended");
        require(amount > 0, "Amount must be positive");

        uint256 tradeKey = _generateTradeKey(optionId, isBuy);
        pendingTrades[msg.sender][tradeKey] = amount;

        emit TradeQueued(msg.sender, optionId, amount);
    }

    /**
     * @notice バッチ処理の実行
     */
    function processBatch(address[] calldata traders, uint256[] calldata optionIds) external nonReentrant {
        require(traders.length == optionIds.length, "Array length mismatch");
        
        uint256 processed = 0;
        for (uint256 i = 0; i < traders.length; i++) {
            address trader = traders[i];
            uint256 optionId = optionIds[i];
            
            uint256 buyKey = _generateTradeKey(optionId, true);
            uint256 sellKey = _generateTradeKey(optionId, false);
            
            if (pendingTrades[trader][buyKey] > 0) {
                _executeTrade(trader, optionId, pendingTrades[trader][buyKey], true);
                delete pendingTrades[trader][buyKey];
                processed++;
            }
            
            if (pendingTrades[trader][sellKey] > 0) {
                _executeTrade(trader, optionId, pendingTrades[trader][sellKey], false);
                delete pendingTrades[trader][sellKey];
                processed++;
            }
        }

        emit BatchProcessed(block.timestamp, processed);
        poolState.lastUpdateTimestamp = uint128(block.timestamp);
    }

    /**
     * @notice プール解決の設定
     */
    function resolvePool(uint8 _winningOption) external onlyFactory notResolved {
        require(block.timestamp >= endTime, "Pool not ended");
        require(_winningOption < optionCount, "Invalid winning option");

        resolved = true;
        winningOption = _winningOption;
        poolState.disputeEndTime = uint128(block.timestamp + 3 days);

        emit PoolResolved(_winningOption);
    }

    /**
     * @notice 解決への異議申し立て
     */
    function submitDisputeVote(uint256 amount) external onlyDuringDisputePeriod {
        require(resolved, "Pool not resolved");
        require(!disputed, "Already disputed");
        require(amount > 0, "Amount must be positive");

        require(IERC20(paymentToken).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        disputeVotes[msg.sender] += amount;

        uint256 totalVotes = getTotalDisputeVotes();
        if (totalVotes >= resolutionThreshold) {
            disputed = true;
        }

        emit DisputeVoteSubmitted(msg.sender, amount);
    }

    /**
     * @notice 紛争解決の処理
     */
    function resolveDispute(bool upheld, uint8 newWinningOption) external onlyFactory {
        require(disputed, "No active dispute");
        require(newWinningOption < optionCount, "Invalid new winning option");

        if (upheld) {
            winningOption = newWinningOption;
        }
        disputed = false;

        emit DisputeResolved(upheld, newWinningOption);
    }

    /**
     * @notice 取引の実行（内部関数）
     */
    function _executeTrade(
        address trader,
        uint256 optionId,
        uint256 amount,
        bool isBuy
    ) internal {
        PoolOption storage option = options[optionId];
        uint256 price = _calculateTradePrice(optionId, amount, isBuy);

        if (isBuy) {
            require(IERC20(paymentToken).transferFrom(trader, address(this), price), "Transfer failed");
            option.reserve += amount;
        } else {
            require(option.reserve >= amount, "Insufficient reserve");
            option.reserve -= amount;
            require(IERC20(paymentToken).transfer(trader, price), "Transfer failed");
        }

        emit OptionTraded(optionId, trader, amount, isBuy);
    }

    /**
     * @notice 取引キーの生成（内部関数）
     */
    function _generateTradeKey(uint256 optionId, bool isBuy) internal pure returns (uint256) {
        return (optionId << 1) | (isBuy ? 1 : 0);
    }

    /**
     * @notice 価格計算（内部関数）
     */
    function _calculateTradePrice(
        uint256 optionId,
        uint256 amount,
        bool isBuy
    ) internal view returns (uint256) {
        PoolOption storage option = options[optionId];
        uint256 k = option.reserve * option.weight;
        
        uint256 newReserve = isBuy ? option.reserve + amount : option.reserve - amount;
        uint256 price = (k / newReserve) * (PRECISION + feeRate) / PRECISION;
        
        return price;
    }

    /**
    * @notice 総紛争投票数の取得
    */
    function getTotalDisputeVotes() public view returns (uint256) {
        uint256 totalVotes = 0;
        // プールに参加した全アドレスの投票を集計
        // 注意: この実装はガス代が高くなる可能性があります
        // 実際の運用では、投票時に別の状態変数で合計を追跡することを推奨
        for (uint256 i = 0; i < optionCount; i++) {
            totalVotes += disputeVotes[msg.sender];
        }
        return totalVotes;
    }
    /**
     * @notice プール情報の取得
     */
    function getPoolInfo() external view returns (
        string memory _description,
        uint256 _endTime,
        uint256 _optionCount,
        bool _resolved,
        uint8 _winningOption,
        uint256 _totalLiquidity,
        bool _disputed,
        uint256 _feeRate
    ) {
        return (
            description,
            endTime,
            optionCount,
            resolved,
            winningOption,
            totalLiquidity,
            disputed,
            feeRate
        );
    }

    /**
     * @notice オプション情報の取得
     */
    function getOptionInfo(uint256 optionId) external view returns (
        string memory _description,
        uint256 _reserve,
        uint256 _weight
    ) {
        require(optionId < optionCount, "Invalid option");
        PoolOption storage option = options[optionId];
        return (
            option.description,
            option.reserve,
            option.weight
        );
    }
}