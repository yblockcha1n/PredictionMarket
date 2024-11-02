// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PredictionMarketPool.sol";

/**
 * @title 予測市場ファクトリー
 * @notice 予測市場プールを作成・管理するファクトリーコントラクト
 */
contract PredictionMarketFactory is Ownable, Pausable {
    using Clones for address;

    // 状態変数
    address public implementation;
    address public paymentToken;
    uint256 public marketCount;
    uint256 public protocolFee;
    uint256 public constant MAX_FEE = 1000; // 10%
    
    // マッピング
    mapping(uint256 => address) public getPool;
    mapping(address => bool) public isPool;
    mapping(address => bool) public operators;
    
    // イベント
    event PoolCreated(
        uint256 indexed marketId, 
        address indexed pool, 
        string description,
        uint256 endTime,
        uint256 optionCount
    );
    event ImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);
    event OperatorUpdated(address indexed operator, bool status);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event PoolDisputed(uint256 indexed marketId, bool upheld, uint8 newWinningOption);
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);

    /**
     * @notice コントラクトのコンストラクタ
     * @param initialOwner 初期オーナーアドレス
     * @param _implementation プール実装コントラクトのアドレス
     * @param _paymentToken 支払いトークンのアドレス
     */
    constructor(
        address initialOwner,
        address _implementation,
        address _paymentToken
    ) Ownable(initialOwner) {
        require(_implementation != address(0), "Invalid implementation");
        require(_paymentToken != address(0), "Invalid payment token");
        implementation = _implementation;
        paymentToken = _paymentToken;
        protocolFee = 50; // 0.5%
    }

    /**
     * @notice 新しいプールの作成
     * @param description 市場の説明
     * @param endTime 終了時間
     * @param optionCount オプション数
     * @param feeRate 手数料率
     * @param resolutionThreshold 解決閾値
     */
    function createPool(
        string memory description,
        uint256 endTime,
        uint256 optionCount,
        uint256 feeRate,
        uint256 resolutionThreshold
    ) external whenNotPaused returns (address pool) {
        require(endTime > block.timestamp, "Invalid end time");
        require(optionCount >= 2, "Min 2 options required");
        require(feeRate <= MAX_FEE, "Fee too high");
        require(bytes(description).length > 0, "Empty description");
        
        // プールの作成
        pool = implementation.clone();
        PredictionMarketPool(pool).initialize(
            address(this),
            paymentToken,
            description,
            endTime,
            optionCount,
            feeRate,
            resolutionThreshold
        );

        // 状態の更新
        uint256 marketId = marketCount++;
        getPool[marketId] = pool;
        isPool[pool] = true;

        emit PoolCreated(
            marketId,
            pool,
            description,
            endTime,
            optionCount
        );
        return pool;
    }

    /**
     * @notice プールの解決
     * @param marketId マーケットID
     * @param winningOption 勝利オプション
     */
    function resolvePool(uint256 marketId, uint8 winningOption) external {
        require(operators[msg.sender] || owner() == msg.sender, "Not authorized");
        address pool = getPool[marketId];
        require(pool != address(0), "Pool not found");
        
        PredictionMarketPool(pool).resolvePool(winningOption);
    }

    /**
     * @notice プールの紛争解決
     * @param marketId マーケットID
     * @param upheld 紛争が認められたか
     * @param newWinningOption 新しい勝利オプション
     */
    function resolveDispute(
        uint256 marketId,
        bool upheld,
        uint8 newWinningOption
    ) external {
        require(operators[msg.sender] || owner() == msg.sender, "Not authorized");
        address pool = getPool[marketId];
        require(pool != address(0), "Pool not found");
        
        PredictionMarketPool(pool).resolveDispute(upheld, newWinningOption);
        emit PoolDisputed(marketId, upheld, newWinningOption);
    }

    /**
     * @notice プール実装の更新
     * @param newImplementation 新しい実装アドレス
     */
    function updateImplementation(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), "Invalid implementation");
        address oldImplementation = implementation;
        implementation = newImplementation;
        emit ImplementationUpdated(oldImplementation, newImplementation);
    }

    /**
     * @notice オペレーター権限の設定
     * @param operator オペレーターアドレス
     * @param status 権限状態
     */
    function setOperator(address operator, bool status) external onlyOwner {
        require(operator != address(0), "Invalid operator");
        operators[operator] = status;
        emit OperatorUpdated(operator, status);
    }

    /**
     * @notice プロトコル手数料の更新
     * @param newFee 新しい手数料率
     */
    function updateProtocolFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, "Fee too high");
        uint256 oldFee = protocolFee;
        protocolFee = newFee;
        emit ProtocolFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice 支払いトークンの更新
     * @param newPaymentToken 新しい支払いトークンアドレス
     */
    function updatePaymentToken(address newPaymentToken) external onlyOwner {
        require(newPaymentToken != address(0), "Invalid payment token");
        address oldToken = paymentToken;
        paymentToken = newPaymentToken;
        emit PaymentTokenUpdated(oldToken, newPaymentToken);
    }

    /**
     * @notice 一時停止の切り替え
     */
    function togglePause() external onlyOwner {
        paused() ? _unpause() : _pause();
    }

    /**
     * @notice プール情報の取得
     * @param marketId マーケットID
     */
    function getPoolInfo(uint256 marketId) external view returns (
        address pool,
        bool exists,
        bool resolved,
        uint8 winningOption,
        uint256 totalLiquidity
    ) {
        pool = getPool[marketId];
        exists = pool != address(0);
        
        if (exists) {
            PredictionMarketPool poolContract = PredictionMarketPool(pool);
            (
                ,   // description
                ,   // endTime
                ,   // optionCount
                resolved,
                winningOption,
                totalLiquidity,
                ,   // disputed
                    // feeRate
            ) = poolContract.getPoolInfo();
        }
    }

    /**
     * @notice マーケットの検証
     * @param marketId マーケットID
     */
    function validateMarket(uint256 marketId) external view returns (bool) {
        address pool = getPool[marketId];
        return pool != address(0) && isPool[pool];
    }
}