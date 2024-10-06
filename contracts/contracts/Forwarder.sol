// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IWETH} from "./interfaces/IWETH.sol";
import {IGasStation} from "./interfaces/IGasStation.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IForwarder} from "./interfaces/IForwarder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Forwarder is IForwarder {
    IWETH internal immutable WETH;
    ISwapRouter internal immutable SWAP_ROUTER;
    IGasStation internal immutable GAS_STATION;

    address internal immutable FORWARD_TO;

    constructor(IGasStation _gasStation, IWETH _weth, ISwapRouter _swapRouter, address _forwardTo) {
        FORWARD_TO = _forwardTo;
        GAS_STATION = _gasStation;
        SWAP_ROUTER = _swapRouter;
        WETH = _weth;
    }

    function forwardTo() public view returns (address) {
        return FORWARD_TO;
    }

    // Flush token to forwardTo
    function flushToken(address token) public {
        IERC20 tokenInstance = IERC20(token);
        uint256 balance = tokenInstance.balanceOf(address(this));
        if (balance == 0) {
            revert EmptyBalance();
        }

        // transfer token to forwardTo
        if (tokenInstance.transfer(FORWARD_TO, balance) == false) {
            revert FailedTokenTransfer(FORWARD_TO, token, balance);
        }

        emit ForwarderFlushed(token, balance);
    }

    // swap amount for native and send both to forwardTo.
    function flushWithNative(
        address token,
        uint256 amount,
        uint256 minRelayerFee
    ) external {
        // swap amount token for native and send both to forwardTo.
        // Use GasStation as much as possible to avoid gas costs on deployment
        uint256 relayerFee = GAS_STATION.getRelayerFee();
        if (relayerFee < minRelayerFee) {
            revert RelayerFeeTooHigh(relayerFee, minRelayerFee);
        }

        uint24 swapFee = GAS_STATION.getSwapFee();

        // swap token for weth
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(WETH),
                recipient: address(this),
                amountIn: amount,
                amountOutMinimum: (amount * 97) / 100, // slippage of 3%
                fee: swapFee, // liquidity providers fee. Example: 3000 bps = 0.3%
                deadline: block.timestamp + 5 * 60, // 5 minutes from the current block time
                sqrtPriceLimitX96: 0
            });
        uint256 amountOut = SWAP_ROUTER.exactInputSingle(params);

        // check that the ETH sent is enough to cover the relayer fee
        if (amountOut < relayerFee) {
            revert NotEnoughForFees(relayerFee, amountOut);
        }

        // unwrap WETH
        IWETH(WETH).withdraw(amountOut);

        // send the ETH to the recipient address
        uint256 forwardAmount = amountOut - relayerFee;
        (bool success, ) = FORWARD_TO.call{value: forwardAmount}("");
        if (success == false) {
            revert FailedEthTransfer(FORWARD_TO, forwardAmount);
        }

        // send fee to relayer
        (success, ) = msg.sender.call{value: relayerFee}("");
        if (success == false) {
            revert FailedEthTransfer(FORWARD_TO, relayerFee);
        }
    }

    //  Default function; Gets called when native is deposited and forwards to forwardTo
    receive() external payable {
        uint256 balance = address(this).balance;
        (bool success, ) = FORWARD_TO.call{value: balance}("");
        if (success == false) {
            revert FailedEthTransfer(FORWARD_TO, balance);
        }

        emit ForwarderFlushed(address(0), balance);
    }
}
