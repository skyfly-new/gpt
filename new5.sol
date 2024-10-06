// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IPancakeSwapV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    
    function getReserves(address tokenA, address tokenB) external view returns (uint112, uint112, uint32);
}

interface IPancakeSwapV3 {
    function swap(
        address recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes calldata params
    ) external returns (uint256 amountOut);
    
    function getLiquidity(address tokenA, address tokenB) external view returns (uint256);
}

contract Arbitrage is ReentrancyGuard, Pausable {
    address public owner;
    uint256 public feePercent;
    
    event ArbitrageExecuted(address[] tokens, uint256 initialAmount, uint256 finalAmount, string strategy);
    event ParametersUpdated(uint256 newFeePercent);
    event CrossChainSwapExecuted(address[] tokens, uint256 amountIn, uint256 amountOut, string destinationChain);
    event SwapExecuted(address tokenFrom, address tokenTo, uint256 amountIn, uint256 amountOut, address exchange);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor(uint256 initialFeePercent) {
        require(validFeePercent(initialFeePercent), "Invalid fee percent");
        owner = msg.sender;
        feePercent = initialFeePercent;
    }

    function updateParameters(uint256 newFeePercent) external onlyOwner whenNotPaused {
        require(validFeePercent(newFeePercent), "Invalid fee percent");
        feePercent = newFeePercent;
        emit ParametersUpdated(newFeePercent);
    }

    function executeArbitrage(
        address[] calldata tokens, 
        uint256 amount, 
        uint256 minReturn, 
        address[] calldata exchanges
    ) external onlyOwner whenNotPaused nonReentrant {
        require(tokens.length > 1, "At least two tokens required");
        require(tokens.length == exchanges.length, "Mismatched tokens and exchanges");
        require(validAmount(amount), "Invalid amount");

        uint256 currentAmount = amount;

        for (uint256 i = 0; i < tokens.length - 1; i++) {
            currentAmount = swap(tokens[i], tokens[i + 1], currentAmount, exchanges[i]);
            require(currentAmount >= minReturn, "Insufficient received amount in swap");
        }

        require(currentAmount > (amount * (100 + feePercent)) / 100, "No profit made");

        emit ArbitrageExecuted(tokens, amount, currentAmount, "Cascading");
    }

    function swap(address tokenFrom, address tokenTo, uint256 amount, address exchange) private returns (uint256) {
        require(validTokenAddress(tokenFrom) && validTokenAddress(tokenTo), "Invalid token addresses");
        require(amount > 0, "Amount must be greater than zero");

        IERC20(tokenFrom).transferFrom(msg.sender, address(this), amount);
        
        uint256 tokenReceived;

        if (exchange == address(0)) {  // PancakeSwap V2
            address[] memory path = new address[](2);
            path[0] = tokenFrom;
            path[1] = tokenTo;
            uint256[] memory amounts = IPancakeSwapV2(exchange).swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
            tokenReceived = amounts[1];
        } else {  // PancakeSwap V3
            tokenReceived = IPancakeSwapV3(exchange).swap(address(this), tokenFrom, tokenTo, amount, 0, "");
        }

        require(tokenReceived > 0, "Swap failed");
        IERC20(tokenTo).transfer(msg.sender, tokenReceived);
        
        emit SwapExecuted(tokenFrom, tokenTo, amount, tokenReceived, exchange);
        return tokenReceived;
    }

    function executeCrossChainSwap(
        address[] calldata tokens, 
        uint256 amount, 
        string calldata targetChain,
        address[] calldata exchanges
    ) external onlyOwner whenNotPaused nonReentrant {
        require(tokens.length > 1, "At least two tokens required");
        require(tokens.length == exchanges.length, "Mismatched tokens and exchanges");
        require(validAmount(amount), "Invalid amount");

        uint256 currentAmount = amount;

        for (uint256 i = 0; i < tokens.length - 1; i++) {
            currentAmount = swap(tokens[i], tokens[i + 1], currentAmount, exchanges[i]);
        }

        emit CrossChainSwapExecuted(tokens, amount, currentAmount, targetChain);
    }

    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(validAmount(amount), "Invalid amount");
        IERC20(token).transfer(owner, amount);
    }

    function togglePause() external onlyOwner {
        paused() ? _unpause() : _pause();
    }

    // Проверки
    function validFeePercent(uint256 fee) internal pure returns (bool) {
        return fee <= 100;
    }

    function validTokenAddress(address token) internal pure returns (bool) {
        return token != address(0);
    }

    function validAmount(uint256 amount) internal pure returns (bool) {
        return amount > 0;
    }
}
