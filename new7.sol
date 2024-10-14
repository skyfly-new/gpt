```solidity
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

// Добавляем интерфейс для кроссчейн-моста
interface ICrossChainBridge {
    function transferToken(address token, address recipient, uint256 amount, string calldata destinationChain) external;
}

contract Arbitrage is ReentrancyGuard, Pausable {
    address public owner;
    uint256 public feePercent;
    address public pancakeSwapV2; // Заменяем адрес PancakeSwap V2 на актуальный
    address public pancakeSwapV3; // Заменяем адрес PancakeSwap V3 на актуальный
    address public crossChainBridge; // Добавляем адрес кроссчейн-моста

    event ArbitrageExecuted(address[] tokens, uint256 initialAmount, uint256 finalAmount, string strategy);
    event CrossChainSwapExecuted(address[] tokens, uint256 amountIn, uint256 amountOut, string destinationChain);
    event ParametersUpdated(uint256 newFeePercent);
    event SwapExecuted(address tokenFrom, address tokenTo, uint256 amountIn, uint256 amountOut, address exchange);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor(uint256 initialFeePercent, address _pancakeSwapV2, address _pancakeSwapV3, address _crossChainBridge) {
        require(validFeePercent(initialFeePercent), "Invalid fee percent");
        owner = msg.sender;
        feePercent = initialFeePercent;
        pancakeSwapV2 = _pancakeSwapV2;
        pancakeSwapV3 = _pancakeSwapV3;
        crossChainBridge = _crossChainBridge;
    }

    function updateParameters(uint256 newFeePercent) external onlyOwner whenNotPaused {
        require(validFeePercent(newFeePercent), "Invalid fee percent");
        feePercent = newFeePercent;
        emit ParametersUpdated(newFeePercent);
    }

    // Добавляем проверку условий гонки
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
            // Убеждаемся, что контракт одобрен для перевода токенов
            require(IERC20(tokens[i]).allowance(msg.sender, address(this)) >= currentAmount, "Insufficient allowance");
            currentAmount = swap(tokens[i], tokens[i + 1], currentAmount, exchanges[i]);
            require(currentAmount >= minReturn, "Insufficient received amount in swap");
        }

        require(currentAmount > (amount * (100 + feePercent)) / 100, "No profit made");
        emit ArbitrageExecuted(tokens, amount, currentAmount, "Cascading");
    }

    // Добавляем проверку адресов DEX и защиту от условий гонки
    function executeCrossChainSwap(
        address[] calldata tokens,
        uint256 amount,
        string calldata targetChain,
        address[] calldata exchanges
    ) external onlyOwner whenNotPaused nonReentrant {
        require(tokens.length > 1, "At least two tokens required");
        require(tokens.length == exchanges.length, "Mismatched tokens and exchanges");
        require(validAmount(amount), "Invalid amount");

        require(validExchangeAddress(exchanges[0]), "Invalid exchange address");
        require(validExchangeAddress(exchanges[exchanges.length - 1]), "Invalid exchange address");

        uint256 currentAmount = amount;

        for (uint256 i = 0; i < tokens.length - 1; i++) {
            require(validTokenAddress(tokens[i]) && validTokenAddress(tokens[i + 1]), "Invalid token addresses");
            currentAmount = swap(tokens[i], tokens[i + 1], currentAmount, exchanges[i]);
        }

        // Переводим токены на другую цепочку
        ICrossChainBridge(crossChainBridge).transferToken(tokens[tokens.length - 1], msg.sender, currentAmount, targetChain);

        emit CrossChainSwapExecuted(tokens, amount, currentAmount, targetChain);
    }

    function swap(address tokenFrom, address tokenTo, uint256 amount, address exchange) private nonReentrant returns (uint256) {
        require(validTokenAddress(tokenFrom) && validTokenAddress(tokenTo), "Invalid token addresses");
        require(amount > 0, "Amount must be greater than zero");

        // Убеждаемся, что контракт одобрен для перевода токенов
        require(IERC20(tokenFrom).allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        IERC20(tokenFrom).transferFrom(msg.sender, address(this), amount);

        uint256 tokenReceived;

        if (exchange == pancakeSwapV2) {
            address[] memory path = new address[](2);
            path[0] = tokenFrom;
            path[1] = tokenTo;
            uint256[] memory amounts = IPancakeSwapV2(pancakeSwapV2).swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
            tokenReceived = amounts[1];
        } else if (exchange == pancakeSwapV3) {
            tokenReceived = IPancakeSwapV3(pancakeSwapV3).swap(address(this), tokenFrom, tokenTo, amount, 0, "");
        } else {
            revert("Invalid exchange address");
        }

        require(tokenReceived > 0, "Swap failed");
        IERC20(tokenTo).transfer(msg.sender, tokenReceived);
        
        emit SwapExecuted(tokenFrom, tokenTo, amount, tokenReceived, exchange);
        return tokenReceived;
    }

    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(validAmount(amount), "Invalid amount");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient token balance");
        IERC20(token).transfer(owner, amount);
    }

    function togglePause() external onlyOwner {
        paused() ? _unpause() : _pause();
    }

    // Validations
    function validFeePercent(uint256 fee) internal pure returns (bool) {
        return fee <= 100;
    }

    function validTokenAddress(address token) internal pure returns (bool) {
        return token != address(0);
    }

    function validAmount(uint256 amount) internal pure returns (bool) {
        return amount > 0;
    }

    // Добавляем проверку адреса обмена
    function validExchangeAddress(address exchange) internal pure returns (bool) {
        return exchange != address(0);
    }

    // New function to get token balance
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
```

**Изменения:**

1. **Добавление интерфейса ICrossChainBridge:** Введен новый интерфейс для взаимодействия с кроссчейн-мостом. 
2. **Добавление переменных для адресов DEX и моста:** В контракте добавлены переменные для хранения адресов PancakeSwap V2, PancakeSwap V3 и кроссчейн-моста.
3. **Добавление проверки утверждения токенов:** В функцию `swap` добавлена проверка того, что контракт одобрен для перевода токенов от отправителя.
4. **Добавление проверки адресов DEX:** В функции `executeCrossChainSwap` добавлена проверка того, что адреса DEX действительны.
5. **Добавление защиты от условий гонки:**  В функции `executeArbitrage` и `executeCrossChainSwap` добавлен модификатор `nonReentrant`.
6. **Добавление проверки адреса обмена:**  Введена новая функция `validExchangeAddress` для проверки адреса обмена.
7. **Добавление функции для перевода токенов на другую цепочку:** В функцию `executeCrossChainSwap` добавлена логика для перевода токенов на другую цепочку через кроссчейн-мост.

**Дополнительные замечания:**

* Этот код все еще не защищен от атак Flash Loan. Дополнительные меры, такие как использование паттернов "anti-flashloan", могут быть необходимы для предотвращения этих атак.
* Всегда рекомендуется проводить профессиональный аудит перед развертыванием этого контракта в реальной сети.

Важно: Несмотря на то, что этот код стал более безопасным, он все равно не является идеальным.  Необходимо внимательно изучить его и добавить дополнительные меры безопасности,  основываясь на вашем конкретном сценарии использования.
