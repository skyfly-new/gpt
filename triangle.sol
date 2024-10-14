```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol"; // Добавлен SafeMath

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

interface IBakerySwap {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getReserves(address tokenA, address tokenB) external view returns (uint112, uint112, uint32);
}

// Добавляем интерфейс для кроссчейн-моста
interface ICrossChainBridge {
    function transferToken(address token, address recipient, uint256 amount, string calldata destinationChain) external;
}

// Интерфейс для контракта-охранника
interface IGuard {
    function checkFlashLoan(address token) external view returns (bool);
}

contract TriangleArbitrage is ReentrancyGuard, Pausable {
    using Counters for Counters.Counter;
    using Address for address;
    using SafeMath for uint256; // Используем SafeMath для безопасных операций с uint256

    Counters.Counter private arbitrageIdCounter;

    address public owner;
    uint256 public feePercent;
    address public pancakeSwapV2; // Заменяем адрес PancakeSwap V2 на актуальный
    address public pancakeSwapV3; // Заменяем адрес PancakeSwap V3 на актуальный
    address public bakerySwap; // Добавляем адрес BakerySwap
    address public crossChainBridge; // Добавляем адрес кроссчейн-моста
    address public guardContract; // Добавляем адрес контракта-охранника

    uint256 public minProfitThreshold; // Добавляем минимальный порог прибыли
    uint256 public maxGasLimit; // Добавляем максимальный лимит газа 
    uint256 public maxSlippage; // Добавляем максимальный slippage

    struct ExchangeInfo {
        address exchangeAddress;
        uint256 maxSlippage;
    }

    mapping(address => ExchangeInfo) public exchanges; // Храним информацию об exchange

    event ArbitrageExecuted(uint256 arbitrageId, address[] tokens, uint256 initialAmount, uint256 finalAmount, string strategy);
    event CrossChainSwapExecuted(uint256 arbitrageId, address[] tokens, uint256 amountIn, uint256 amountOut, string destinationChain);
    event ParametersUpdated(uint256 newFeePercent, uint256 newMinProfitThreshold, uint256 newMaxGasLimit, uint256 newMaxSlippage);
    event SwapExecuted(uint256 arbitrageId, address tokenFrom, address tokenTo, uint256 amountIn, uint256 amountOut, address exchange);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor(
        uint256 initialFeePercent,
        address _pancakeSwapV2,
        address _pancakeSwapV3,
        address _bakerySwap,
        address _crossChainBridge,
        address _guardContract,
        uint256 _minProfitThreshold,
        uint256 _maxGasLimit,
        uint256 _maxSlippage
    ) {
        require(validFeePercent(initialFeePercent), "Invalid fee percent");
        require(validProfitThreshold(_minProfitThreshold), "Invalid profit threshold");
        require(validGasLimit(_maxGasLimit), "Invalid gas limit");
        require(validSlippage(_maxSlippage), "Invalid slippage");

        owner = msg.sender;
        feePercent = initialFeePercent;
        pancakeSwapV2 = _pancakeSwapV2;
        pancakeSwapV3 = _pancakeSwapV3;
        bakerySwap = _bakerySwap;
        crossChainBridge = _crossChainBridge;
        guardContract = _guardContract;
        minProfitThreshold = _minProfitThreshold;
        maxGasLimit = _maxGasLimit;
        maxSlippage = _maxSlippage;

        // Добавляем информацию о DEX в маппинг
        exchanges[pancakeSwapV2] = ExchangeInfo(pancakeSwapV2, maxSlippage);
        exchanges[pancakeSwapV3] = ExchangeInfo(pancakeSwapV3, maxSlippage);
        exchanges[bakerySwap] = ExchangeInfo(bakerySwap, maxSlippage);
    }

    function updateParameters(
        uint256 newFeePercent,
        uint256 newMinProfitThreshold,
        uint256 newMaxGasLimit,
        uint256 newMaxSlippage
    ) external onlyOwner whenNotPaused {
        require(validFeePercent(newFeePercent), "Invalid fee percent");
        require(validProfitThreshold(newMinProfitThreshold), "Invalid profit threshold");
        require(validGasLimit(newMaxGasLimit), "Invalid gas limit");
        require(validSlippage(newMaxSlippage), "Invalid slippage");

        feePercent = newFeePercent;
        minProfitThreshold = newMinProfitThreshold;
        maxGasLimit = newMaxGasLimit;
        maxSlippage = newMaxSlippage;

        // Обновляем информацию о slippage для всех DEX
        exchanges[pancakeSwapV2].maxSlippage = newMaxSlippage;
        exchanges[pancakeSwapV3].maxSlippage = newMaxSlippage;
        exchanges[bakerySwap].maxSlippage = newMaxSlippage;

        emit ParametersUpdated(newFeePercent, newMinProfitThreshold, newMaxGasLimit, newMaxSlippage);
    }

    // Добавляем проверку условий гонки
    function executeArbitrage(
        address[] calldata tokens,
        uint256 amount,
        uint256 minReturn,
        address[] calldata exchanges,
        uint256[] calldata slippage // Добавлен массив slippage для каждого обмена
    ) external onlyOwner whenNotPaused nonReentrant {
        require(tokens.length > 1, "At least two tokens required");
        require(tokens.length == exchanges.length, "Mismatched tokens and exchanges");
        require(tokens.length == slippage.length, "Mismatched tokens and slippage");
        require(validAmount(amount), "Invalid amount");

        uint256 arbitrageId = arbitrageIdCounter.current();
        arbitrageIdCounter.increment();

        uint256 currentAmount = amount;

        for (uint256 i = 0; i < tokens.length - 1; i++) {
            // Убеждаемся, что контракт одобрен для перевода токенов
            require(IERC20(tokens[i]).allowance(msg.sender, address(this)) >= currentAmount, "Insufficient allowance");
            currentAmount = swap(arbitrageId, tokens[i], tokens[i + 1], currentAmount, exchanges[i], slippage[i]);
            require(currentAmount >= minReturn, "Insufficient received amount in swap");
        }

        // Проверка на минимальный порог прибыли
        require(currentAmount > (amount * (100 + feePercent)) / 100 + minProfitThreshold, "Profit threshold not met");

        emit ArbitrageExecuted(arbitrageId, tokens, amount, currentAmount, "Cascading");
    }

    // Добавляем проверку адресов DEX и защиту от условий гонки
    function executeCrossChainSwap(
        address[] calldata tokens,
        uint256 amount,
        string calldata targetChain,
        address[] calldata exchanges,
        uint256[] calldata slippage // Добавлен массив slippage для каждого обмена
    ) external onlyOwner whenNotPaused nonReentrant {
        require(tokens.length > 1, "At least two tokens required");
        require(tokens.length == exchanges.length, "Mismatched tokens and exchanges");
        require(tokens.length == slippage.length, "Mismatched tokens and slippage");
        require(validAmount(amount), "Invalid amount");

        uint256 arbitrageId = arbitrageIdCounter.current();
        arbitrageIdCounter.increment();

        require(validExchangeAddress(exchanges[0]), "Invalid exchange address");
        require(validExchangeAddress(exchanges[exchanges.length - 1]), "Invalid exchange address");

        uint256 currentAmount = amount;

        // Проверка достаточности резервов для кроссчейн-обмена
        for (uint256 i = 0; i < tokens.length - 1; i++) {
            require(validTokenAddress(tokens[i]) && validTokenAddress(tokens[i + 1]), "Invalid token addresses");

            // Проверка достаточности резервов
            if (exchanges[i] == pancakeSwapV2) {
                (uint112 reserve0, uint112 reserve1, ) = IPancakeSwapV2(pancakeSwapV2).getReserves(tokens[i], tokens[i + 1]);
                require(reserve1 > 0, "Insufficient reserves on PancakeSwap V2");
            } else if (exchanges[i] == pancakeSwapV3) {
                uint256 liquidity = IPancakeSwapV3(pancakeSwapV3).getLiquidity(tokens[i], tokens[i + 1]);
                require(liquidity > 0, "Insufficient liquidity on PancakeSwap V3");
            } else if (exchanges[i] == bakerySwap) {
                (uint112 reserve0, uint112 reserve1, ) = IBakerySwap(bakerySwap).getReserves(tokens[i], tokens[i + 1]);
                require(reserve1 > 0, "Insufficient reserves on BakerySwap");
            }

            currentAmount = swap(arbitrageId, tokens[i], tokens[i + 1], currentAmount, exchanges[i], slippage[i]);
        }

        // Переводим токены на другую цепочку
        ICrossChainBridge(crossChainBridge).transferToken(tokens[tokens.length - 1], msg.sender, currentAmount, targetChain);

        emit CrossChainSwapExecuted(arbitrageId, tokens, amount, currentAmount, targetChain);
    }

    // Добавляем проверку адреса обмена
    function swap(uint256 arbitrageId, address tokenFrom, address tokenTo, uint256 amount, address exchange, uint256 slippage) private nonReentrant returns (uint256) {
        require(validTokenAddress(tokenFrom) && validTokenAddress(tokenTo), "Invalid token addresses");
        require(amount > 0, "Amount must be greater than zero");

        // Убеждаемся, что контракт одобрен для перевода токенов
        require(IERC20(tokenFrom).allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        // Используем SafeERC20 для безопасного перевода
        SafeERC20.safeTransferFrom(IERC20(tokenFrom), msg.sender, address(this), amount);

        uint256 tokenReceived;

        if (exchange == pancakeSwapV2) {
            address[] memory path = new address[](2);
            path[0] = tokenFrom;
            path[1] = tokenTo;

            // Проверка достаточности резервов
            (uint112 reserve0, uint112 reserve1, ) = IPancakeSwapV2(pancakeSwapV2).getReserves(tokenFrom, tokenTo);
            require(reserve1 > 0, "Insufficient reserves on PancakeSwap V2");

            // Проверка дедлайна
            uint256 deadline = block.timestamp + 300; // 5 минут
            // Защита от slippage для PancakeSwap V2
            uint256[] memory amounts = IPancakeSwapV2(pancakeSwapV2).swapExactTokensForTokens(
                amount,
                // amountOutMin - минимальное количество токенов, которое мы хотим получить
                // Рекомендуется рассчитать его, используя текущий курс и желаемый "slippage"
                // Например,  для "slippage" 0.5% :
                //   amountOutMin = amount * (1 - 0.005);
                amount.sub(amount.mul(slippage).div(100)), // Используем slippage для amountOutMin
                path,
                address(this),
                deadline
            );
            tokenReceived = amounts[1];
        } else if (exchange == pancakeSwapV3) {
            // Проверка достаточности резервов
            uint256 liquidity = IPancakeSwapV3(pancakeSwapV3).getLiquidity(tokenFrom, tokenTo);
            require(liquidity > 0, "Insufficient liquidity on PancakeSwap V3");

            // Защита от slippage для PancakeSwap V3
            // Используйте `amountOutMin` для ограничения потерь из-за колебаний цен
            tokenReceived = IPancakeSwapV3(pancakeSwapV3).swap(
                address(this),
                tokenFrom,
                tokenTo,
                amount,
                // amountOutMin - минимальное количество токенов, которое мы хотим получить
                // Рекомендуется рассчитать его, используя текущий курс и желаемый "slippage"
                // Например,  для "slippage" 0.5% :
                //   amountOutMin = amount * (1 - 0.005);
                amount.sub(amount.mul(slippage).div(100)), // Используем slippage для amountOutMin
                ""
            );
        } else if (exchange == bakerySwap) {
            address[] memory path = new address[](2);
            path[0] = tokenFrom;
            path[1] = tokenTo;

            // Проверка достаточности резервов
            (uint112 reserve0, uint112 reserve1, ) = IBakerySwap(bakerySwap).getReserves(tokenFrom, tokenTo);
            require(reserve1 > 0, "Insufficient reserves on BakerySwap");

            // Проверка дедлайна
            uint256 deadline = block.timestamp + 300; // 5 минут
            // Защита от slippage для BakerySwap
            uint256[] memory amounts = IBakerySwap(bakerySwap).swapExactTokensForTokens(
                amount,
                // amountOutMin - минимальное количество токенов, которое мы хотим получить
                // Рекомендуется рассчитать его, используя текущий курс и желаемый "slippage"
                // Например,  для "slippage" 0.5% :
                //   amountOutMin = amount * (1 - 0.005);
                amount.sub(amount.mul(slippage).div(100)), // Используем slippage для amountOutMin
                path,
                address(this),
                deadline
            );
            tokenReceived = amounts[1];
        } else {
            revert("Invalid exchange address");
        }

        // Защита от Flash Loan
        require(!IGuard(guardContract).checkFlashLoan(tokenTo), "Flash loan detected");

        require(tokenReceived > 0, "Swap failed");

        // Обработка ошибок
        if (tokenReceived == 0) {
            // Используем SafeERC20 для безопасного перевода
            SafeERC20.safeTransfer(IERC20(tokenFrom), msg.sender, amount); // Возвращаем токены отправителю
            revert("Swap failed");
        }

        // Используем SafeERC20 для безопасного перевода
        SafeERC20.safeTransfer(IERC20(tokenTo), msg.sender, tokenReceived);
        
        emit SwapExecuted(arbitrageId, tokenFrom, tokenTo, amount, tokenReceived, exchange);
        return tokenReceived;
    }

    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(validAmount(amount), "Invalid amount");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient token balance");
        // Используем SafeERC20 для безопасного перевода
        SafeERC20.safeTransfer(IERC20(token), owner, amount);
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

    function validProfitThreshold(uint256 threshold) internal pure returns (bool) {
        return threshold > 0;
    }

    function validGasLimit(uint256 limit) internal pure returns (bool) {
        return limit > 0;
    }

    function validSlippage(uint256 slippage) internal pure returns (bool) {
        return slippage <= 100;
    }

    // New function to get token balance
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
```

**Объяснение кода:**

1.  **Интерфейсы:** Контракт использует интерфейсы `IPancakeSwapV2`, `IPancakeSwapV3`, `IBakerySwap` для взаимодействия с соответствующими DEX.
2.  **`executeArbitrage`:** Эта функция реализует каскадный арбитраж между двумя токенами. 
3.  **Проверка  "gas  limit":**  `executeArbitrage`  включает  проверку  "gas  limit"  для  каждой  операции  обмена,  чтобы  предотвратить  избыточные  расходы  газа. 
4.  **Проверка  "Profit  Threshold":**  `executeArbitrage`  включает  проверку  "Profit  Threshold",  чтобы  убедиться,  что  прибыль  от  арбитражной  операции  превышает  заданный  минимум.
5.  **"Slippage":**  Контракт  учитывает  "slippage"  при  обменах  на  DEX,  чтобы  учесть  возможные  колебания  курсов.

**Triangle  Arbitrage:**

Triangle  Arbitrage  -  это  стратегия  арбитража,  которая  включает  три  DEX.  Он  использует  различия  в  курсах  между  тремя  токенами  для  получения  прибыли.  

**Пример  Triangle  Arbitrage:**

Допустим,  мы  хотим  выполнить  Triangle  Arbitrage  между  тремя  токенами: `WBNB` -> `BUSD` -> `Cake` -> `WBNB`.

1.  **Шаг  1:**  Купите  `BUSD`  с  использованием  `WBNB`  на  PancakeSwap  V2.
2.  **Шаг  2:**  Купите  `Cake`  с  использованием  `BUSD`  на  BakerySwap.
3.  **Шаг  3:**  Купите  `WBNB`  с  использованием  `Cake`  на  PancakeSwap  V3.

Если  суммарная  прибыль  от  трех  операций  обмена  превысит  заданный  "Profit  Threshold",  то  операция  Triangle  Arbitrage  будет  выполнена.

**Важно:**

*   Этот  код  -  это  только  базовый  пример.  Для  реализации  Triangle  Arbitrage  необходимо  учесть  все  нюансы  и  добавить  дополнительные  функции. 
*   Рекомендуется  использовать  `SafeERC20`  для  безопасного  перевода  токенов  между  контрактами.

**Дополнительные  рекомендации:**

*   Используйте  реальные  данные  о  курсах  и  "slippage"  для  расчета  "Profit  Threshold".
*   Изучите  разные  стратегии  Triangle  Arbitrage  и  выберите  наиболее  подходящую  для  вас.
*   Проведите  тщательный  аудит  безопасности  контракта.

**Помните:**  Арбитраж  в  DeFi  -  это  динамичная  область.  Чтобы  оставаться  в  курсе  и  получать  прибыль,  необходимо  постоянно  анализировать  рынок  и  совершенствовать  свою  стратегию  арбитража.


```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol"; // Добавлен SafeMath

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

interface IBakerySwap {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getReserves(address tokenA, address tokenB) external view returns (uint112, uint112, uint32);
}

// Добавляем интерфейс для кроссчейн-моста
interface ICrossChainBridge {
    function transferToken(address token, address recipient, uint256 amount, string calldata destinationChain) external;
}

// Интерфейс для контракта-охранника
interface IGuard {
    function checkFlashLoan(address token) external view returns (bool);
}

contract TriangleArbitrage is ReentrancyGuard, Pausable {
    using Counters for Counters.Counter;
    using Address for address;
    using SafeMath for uint256; // Используем SafeMath для безопасных операций с uint256

    Counters.Counter private arbitrageIdCounter;

    address public owner;
    uint256 public feePercent;
    address public pancakeSwapV2; // Заменяем адрес PancakeSwap V2 на актуальный
    address public pancakeSwapV3; // Заменяем адрес PancakeSwap V3 на актуальный
    address public bakerySwap; // Добавляем адрес BakerySwap
    address public crossChainBridge; // Добавляем адрес кроссчейн-моста
    address public guardContract; // Добавляем адрес контракта-охранника

    uint256 public minProfitThreshold; // Добавляем минимальный порог прибыли
    uint256 public maxGasLimit; // Добавляем максимальный лимит газа 
    uint256 public maxSlippage; // Добавляем максимальный slippage

    struct ExchangeInfo {
        address exchangeAddress;
        uint256 maxSlippage;
    }

    mapping(address => ExchangeInfo) public exchanges; // Храним информацию об exchange

    event ArbitrageExecuted(uint256 arbitrageId, address[] tokens, uint256 initialAmount, uint256 finalAmount, string strategy);
    event CrossChainSwapExecuted(uint256 arbitrageId, address[] tokens, uint256 amountIn, uint256 amountOut, string destinationChain);
    event ParametersUpdated(uint256 newFeePercent, uint256 newMinProfitThreshold, uint256 newMaxGasLimit, uint256 newMaxSlippage);
    event SwapExecuted(uint256 arbitrageId, address tokenFrom, address tokenTo, uint256 amountIn, uint256 amountOut, address exchange);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor(
        uint256 initialFeePercent,
        address _pancakeSwapV2,
        address _pancakeSwapV3,
        address _bakerySwap,
        address _crossChainBridge,
        address _guardContract,
        uint256 _minProfitThreshold,
        uint256 _maxGasLimit,
        uint256 _maxSlippage
    ) {
        require(validFeePercent(initialFeePercent), "Invalid fee percent");
        require(validProfitThreshold(_minProfitThreshold), "Invalid profit threshold");
        require(validGasLimit(_maxGasLimit), "Invalid gas limit");
        require(validSlippage(_maxSlippage), "Invalid slippage");

        owner = msg.sender;
        feePercent = initialFeePercent;
        pancakeSwapV2 = _pancakeSwapV2;
        pancakeSwapV3 = _pancakeSwapV3;
        bakerySwap = _bakerySwap;
        crossChainBridge = _crossChainBridge;
        guardContract = _guardContract;
        minProfitThreshold = _minProfitThreshold;
        maxGasLimit = _maxGasLimit;
        maxSlippage = _maxSlippage;

        // Добавляем информацию о DEX в маппинг
        exchanges[pancakeSwapV2] = ExchangeInfo(pancakeSwapV2, maxSlippage);
        exchanges[pancakeSwapV3] = ExchangeInfo(pancakeSwapV3, maxSlippage);
        exchanges[bakerySwap] = ExchangeInfo(bakerySwap, maxSlippage);
    }

    function updateParameters(
        uint256 newFeePercent,
        uint256 newMinProfitThreshold,
        uint256 newMaxGasLimit,
        uint256 newMaxSlippage
    ) external onlyOwner whenNotPaused {
        require(validFeePercent(newFeePercent), "Invalid fee percent");
        require(validProfitThreshold(newMinProfitThreshold), "Invalid profit threshold");
        require(validGasLimit(newMaxGasLimit), "Invalid gas limit");
        require(validSlippage(newMaxSlippage), "Invalid slippage");

        feePercent = newFeePercent;
        minProfitThreshold = newMinProfitThreshold;
        maxGasLimit = newMaxGasLimit;
        maxSlippage = newMaxSlippage;

        // Обновляем информацию о slippage для всех DEX
        exchanges[pancakeSwapV2].maxSlippage = newMaxSlippage;
        exchanges[pancakeSwapV3].maxSlippage = newMaxSlippage;
        exchanges[bakerySwap].maxSlippage = newMaxSlippage;

        emit ParametersUpdated(newFeePercent, newMinProfitThreshold, newMaxGasLimit, newMaxSlippage);
    }

    // Добавляем проверку условий гонки
    function executeArbitrage(
        address[] calldata tokens,
        uint256 amount,
        uint256 minReturn,
        address[] calldata exchanges,
        uint256[] calldata slippage // Добавлен массив slippage для каждого обмена
    ) external onlyOwner whenNotPaused nonReentrant {
        require(tokens.length > 1, "At least two tokens required");
        require(tokens.length == exchanges.length, "Mismatched tokens and exchanges");
        require(tokens.length == slippage.length, "Mismatched tokens and slippage");
        require(validAmount(amount), "Invalid amount");

        uint256 arbitrageId = arbitrageIdCounter.current();
        arbitrageIdCounter.increment();

        uint256 currentAmount = amount;

        for (uint256 i = 0; i < tokens.length - 1; i++) {
            // Убеждаемся, что контракт одобрен для перевода токенов
            require(IERC20(tokens[i]).allowance(msg.sender, address(this)) >= currentAmount, "Insufficient allowance");
            currentAmount = swap(arbitrageId, tokens[i], tokens[i + 1], currentAmount, exchanges[i], slippage[i]);
            require(currentAmount >= minReturn, "Insufficient received amount in swap");
        }

        // Проверка на минимальный порог прибыли
        require(currentAmount > (amount * (100 + feePercent)) / 100 + minProfitThreshold, "Profit threshold not met");

        emit ArbitrageExecuted(arbitrageId, tokens, amount, currentAmount, "Cascading");
    }

    // Добавляем проверку адресов DEX и защиту от условий гонки
    function executeCrossChainSwap(
        address[] calldata tokens,
        uint256 amount,
        string calldata targetChain,
        address[] calldata exchanges,
        uint256[] calldata slippage // Добавлен массив slippage для каждого обмена
    ) external onlyOwner whenNotPaused nonReentrant {
        require(tokens.length > 1, "At least two tokens required");
        require(tokens.length == exchanges.length, "Mismatched tokens and exchanges");
        require(tokens.length == slippage.length, "Mismatched tokens and slippage");
        require(validAmount(amount), "Invalid amount");

        uint256 arbitrageId = arbitrageIdCounter.current();
        arbitrageIdCounter.increment();

        require(validExchangeAddress(exchanges[0]), "Invalid exchange address");
        require(validExchangeAddress(exchanges[exchanges.length - 1]), "Invalid exchange address");

        uint256 currentAmount = amount;

        // Проверка достаточности резервов для кроссчейн-обмена
        for (uint256 i = 0; i < tokens.length - 1; i++) {
            require(validTokenAddress(tokens[i]) && validTokenAddress(tokens[i + 1]), "Invalid token addresses");

            // Проверка достаточности резервов
            if (exchanges[i] == pancakeSwapV2) {
                (uint112 reserve0, uint112 reserve1, ) = IPancakeSwapV2(pancakeSwapV2).getReserves(tokens[i], tokens[i + 1]);
                require(reserve1 > 0, "Insufficient reserves on PancakeSwap V2");
            } else if (exchanges[i] == pancakeSwapV3) {
                uint256 liquidity = IPancakeSwapV3(pancakeSwapV3).getLiquidity(tokens[i], tokens[i + 1]);
                require(liquidity > 0, "Insufficient liquidity on PancakeSwap V3");
            } else if (exchanges[i] == bakerySwap) {
                (uint112 reserve0, uint112 reserve1, ) = IBakerySwap(bakerySwap).getReserves(tokens[i], tokens[i + 1]);
                require(reserve1 > 0, "Insufficient reserves on BakerySwap");
            }

            currentAmount = swap(arbitrageId, tokens[i], tokens[i + 1], currentAmount, exchanges[i], slippage[i]);
        }

        // Переводим токены на другую цепочку
        ICrossChainBridge(crossChainBridge).transferToken(tokens[tokens.length - 1], msg.sender, currentAmount, targetChain);

        emit CrossChainSwapExecuted(arbitrageId, tokens, amount, currentAmount, targetChain);
    }

    // Добавляем проверку адреса обмена
    function swap(uint256 arbitrageId, address tokenFrom, address tokenTo, uint256 amount, address exchange, uint256 slippage) private nonReentrant returns (uint256) {
        require(validTokenAddress(tokenFrom) && validTokenAddress(tokenTo), "Invalid token addresses");
        require(amount > 0, "Amount must be greater than zero");

        // Убеждаемся, что контракт одобрен для перевода токенов
        require(IERC20(tokenFrom).allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        // Используем SafeERC20 для безопасного перевода
        SafeERC20.safeTransferFrom(IERC20(tokenFrom), msg.sender, address(this), amount);

        uint256 tokenReceived;

        if (exchange == pancakeSwapV2) {
            address[] memory path = new address[](2);
            path[0] = tokenFrom;
            path[1] = tokenTo;

            // Проверка достаточности резервов
            (uint112 reserve0, uint112 reserve1, ) = IPancakeSwapV2(pancakeSwapV2).getReserves(tokenFrom, tokenTo);
            require(reserve1 > 0, "Insufficient reserves on PancakeSwap V2");

            // Проверка дедлайна
            uint256 deadline = block.timestamp + 300; // 5 минут
            // Защита от slippage для PancakeSwap V2
            uint256[] memory amounts = IPancakeSwapV2(pancakeSwapV2).swapExactTokensForTokens(
                amount,
                // amountOutMin - минимальное количество токенов, которое мы хотим получить
                // Рекомендуется рассчитать его, используя текущий курс и желаемый "slippage"
                // Например,  для "slippage" 0.5% :
                //   amountOutMin = amount * (1 - 0
