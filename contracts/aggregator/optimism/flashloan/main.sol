//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./helpers.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract FlashAggregatorOptimism is Helper {
    using SafeERC20 for IERC20;

    event LogFlashloan(
        address indexed account,
        uint256 indexed route,
        address[] tokens,
        uint256[] amounts
    );

    struct UniswapFlashInfo {
        address sender;
        PoolKey key;
        bytes data;
    }

    /**
     * @dev Callback function for uniswap flashloan.
     * @notice Callback function for uniswap flashloan.
     * @param fee0 The fee from calling flash for token0
     * @param fee1 The fee from calling flash for token1
     * @param data extra data passed(includes route info aswell).
     */
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes memory data
    ) external verifyDataHash(data) {
        FlashloanVariables memory instaLoanVariables_;
        UniswapFlashInfo memory uniswapFlashData_;
        (
            instaLoanVariables_._tokens,
            instaLoanVariables_._amounts,
            uniswapFlashData_.sender,
            uniswapFlashData_.key,
            uniswapFlashData_.data
        ) = abi.decode(data, (address[], uint256[], address, PoolKey, bytes));

        address pool = computeAddress(
            uniswapFactoryAddr,
            uniswapFlashData_.key
        );
        require(msg.sender == pool, "invalid-sender");
        instaLoanVariables_._iniBals = calculateBalances(
            instaLoanVariables_._tokens,
            address(this)
        );

        uint256 feeBPS = uint256(uniswapFlashData_.key.fee / 100);
        if (feeBPS < InstaFeeBPS) {
            feeBPS = InstaFeeBPS;
        }

        instaLoanVariables_._instaFees = calculateFees(
            instaLoanVariables_._amounts,
            feeBPS
        );

        safeTransfer(instaLoanVariables_, uniswapFlashData_.sender);

        if (checkIfDsa(uniswapFlashData_.sender)) {
            Address.functionCall(
                uniswapFlashData_.sender,
                uniswapFlashData_.data,
                "DSA-flashloan-fallback-failed"
            );
        } else {
            InstaFlashReceiverInterface(uniswapFlashData_.sender)
                .executeOperation(
                    instaLoanVariables_._tokens,
                    instaLoanVariables_._amounts,
                    instaLoanVariables_._instaFees,
                    uniswapFlashData_.sender,
                    uniswapFlashData_.data
                );
        }

        instaLoanVariables_._finBals = calculateBalances(
            instaLoanVariables_._tokens,
            address(this)
        );

        validateFlashloan(instaLoanVariables_);
        uint256[] memory fees_;
        if (instaLoanVariables_._tokens.length == 2) {
            fees_ = new uint256[](2);
            fees_[0] = fee0;
            fees_[1] = fee1;
        } else if (
            instaLoanVariables_._tokens[0] == uniswapFlashData_.key.token0
        ) {
            fees_ = new uint256[](1);
            fees_[0] = fee0;
        } else {
            fees_ = new uint256[](1);
            fees_[0] = fee1;
        }
        safeTransferWithFee(instaLoanVariables_, fees_, msg.sender);
    }

    function executeOperation(
        address[] memory _assets,
        uint256[] memory _amounts,
        uint256[] memory _premiums,
        address _initiator,
        bytes memory _data
    ) external verifyDataHash(_data) returns (bool) {
        require(_initiator == address(this), "not-same-sender");
        require(msg.sender == address(aaveLending), "not-aave-sender");

        FlashloanVariables memory instaLoanVariables_;

        (address sender_, bytes memory data_) = abi.decode(
            _data,
            (address, bytes)
        );

        instaLoanVariables_._tokens = _assets;
        instaLoanVariables_._amounts = _amounts;
        instaLoanVariables_._instaFees = calculateFees(
            _amounts,
            calculateFeeBPS(1, sender_)
        );
        instaLoanVariables_._iniBals = calculateBalances(
            _assets,
            address(this)
        );

        safeApprove(instaLoanVariables_, _premiums, address(aaveLending));
        safeTransfer(instaLoanVariables_, sender_);

        if (checkIfDsa(sender_)) {
            Address.functionCall(
                sender_,
                data_,
                "DSA-flashloan-fallback-failed"
            );
        } else {
            InstaFlashReceiverInterface(sender_).executeOperation(
                _assets,
                _amounts,
                instaLoanVariables_._instaFees,
                sender_,
                data_
            );
        }

        instaLoanVariables_._finBals = calculateBalances(
            _assets,
            address(this)
        );
        validateFlashloan(instaLoanVariables_);

        return true;
    }

    /**
  * @dev Middle function for route 1.
     * @notice Middle function for route 1.
     * @param _tokens list of token addresses for flashloan.
     * @param _amounts list of amounts for the corresponding assets or amount of ether to borrow as collateral for flashloan.
     * @param _data extra data passed.
     */
    function routeAave(
        address[] memory _tokens,
        uint256[] memory _amounts,
        bytes memory _data
    ) internal {
        bytes memory data_ = abi.encode(msg.sender, _data);
        uint256 length_ = _tokens.length;
        uint256[] memory _modes = new uint256[](length_);
        for (uint256 i = 0; i < length_; i++) {
            _modes[i] = 0;
        }
        dataHash = bytes32(keccak256(data_));
        aaveLending.flashLoan(
            address(this),
            _tokens,
            _amounts,
            _modes,
            address(0),
            data_,
            3228
        );
    }


    /**
     * @dev Main function for flashloan for all routes. Calls the middle functions according to routes.
     * @notice Main function for flashloan for all routes. Calls the middle functions according to routes.
     * @param _tokens token addresses for flashloan.
     * @param _amounts list of amounts for the corresponding assets.
     * @param _route route for flashloan.
     * @param _data extra data passed.
     */
    function flashLoan(
        address[] memory _tokens,
        uint256[] memory _amounts,
        uint256 _route,
        bytes calldata _data,
        bytes calldata _instadata
    ) external reentrancy {
        require(_tokens.length == _amounts.length, "array-lengths-not-same");

        (_tokens, _amounts) = bubbleSort(_tokens, _amounts);
        validateTokens(_tokens);

        if (_route == 1) {
            routeAave(_tokens, _amounts, _data);
        } else {
            revert("route-does-not-exist");
        }

        emit LogFlashloan(msg.sender, _route, _tokens, _amounts);
    }

    /**
     * @dev Function to get the list of available routes.
     * @notice Function to get the list of available routes.
     */
    function getRoutes() public pure returns (uint16[] memory routes_) {
        routes_ = new uint16[](1);
        routes_[0] = 8;
    }

    /**
     * @dev Function to transfer fee to the treasury.
     * @notice Function to transfer fee to the treasury.
     * @param _tokens token addresses for transferring fee to treasury.
     */
    function transferFeeToTreasury(address[] memory _tokens) public {
        for (uint256 i = 0; i < _tokens.length; i++) {
            IERC20 token_ = IERC20(_tokens[i]);
            uint256 decimals_ = TokenInterface(_tokens[i]).decimals();
            uint256 amtToSub_ = decimals_ == 18 ? 1e10 : decimals_ > 12
                ? 10000
                : decimals_ > 7
                ? 100
                : 10;
            uint256 amtToTransfer_ = token_.balanceOf(address(this)) > amtToSub_
                ? (token_.balanceOf(address(this)) - amtToSub_)
                : 0;
            if (amtToTransfer_ > 0)
                token_.safeTransfer(treasuryAddr, amtToTransfer_);
        }
    }
}

contract InstaFlashAggregatorOptimism is FlashAggregatorOptimism {
    function initialize() public {
        require(status == 0, "cannot-call-again");
        status = 1;
    }

    receive() external payable {}
}
