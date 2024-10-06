// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Интерфейс стандартного токена ERC20
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Интерфейс для Uniswap V2 Router
interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// Интерфейс для Uniswap V3 Router
interface IUniswapV3Router {
    function exactInput(
        // Параметры для V3 обмена (здесь мы подразумеваем строгое соблюдение интерфейса)
    ) external returns (uint256 amountOut);
}

contract Arbitrage {
    address public owner;
    IUniswapV2Router public uniswapV2Router;
    IUniswapV3Router public uniswapV3Router;

    event TradeExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool success
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the contract owner");
        _;
    }

    modifier checkBalance(address token, uint256 amount) {
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient contract balance");
        _;
    }

    constructor(address _uniswapV2Router, address _uniswapV3Router) {
        owner = msg.sender;
        uniswapV2Router = IUniswapV2Router(_uniswapV2Router);
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
    }

    // Функция для выполнения арбитража
    function executeArbitrage(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bool useV2ToV3
    ) external onlyOwner checkBalance(tokenIn, amountIn) {
        // Переносим токены в контракт
        IERC20(tokenIn).approve(address(uniswapV2Router), amountIn);

        uint256 amountOut;

        if (useV2ToV3) {
            // Обмен через Uniswap V2
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;

            // Выполнение обмена в V2
            uint256[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
                amountIn,
                amountOutMin,
                path,
                address(this),
                block.timestamp
            );

            amountOut = amounts[1];
        } else {
            // В V3 здесь предполагается, что у нас есть необходимые параметры
            amountOut = uniswapV3Router.exactInput(
                // Параметры для обмена
            );
        }

        emit TradeExecuted(tokenIn, tokenOut, amountIn, amountOut, amountOut >= amountOutMin);
    }

    // Функция для вывода токенов из контракта
    function withdrawToken(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        IERC20(token).transfer(owner, amount);
    }
}

Объяснение ключевых изменений:
Интерфейсы ERC20: Включены необходимые функции для работы с токенами ERC20.
Модификаторы:
onlyOwner: Позволяет только владельцу контракта выполнять определенные функции.
checkBalance: Проверяет, достаточно ли токенов на балансе контракта перед выполнением обмена.
Событие TradeExecuted: Подтверждает выполнение обмена с логированием для ясности.
Функция executeArbitrage: Принимает параметры для более гибкой работы, включая выбор между V2 и V3.
Функция withdrawToken: Позволяет владельцу выводить токены из контракта.
Замечания:
Пример функции exactInput для V3 может потребовать конкретных параметров, которые вы должны будете определить в зависимости от вашей реализации.
Убедитесь, что ваш контракт проверяет наличие необходимых разрешений токенов перед их обменом.
Для тестирования обязательно используйте тестовую сеть перед развёртыванием на основной сети.
