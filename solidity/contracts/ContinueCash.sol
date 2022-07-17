// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract ContinueCashLogic {
	uint public stock_priceDiv;
	uint public money_priceMul;

	uint public createdRobotCount;
	uint[] private robotIdList;
	mapping(uint => uint) public robotInfoMap;

	address constant SEP206Contract = address(bytes20(uint160(0x2711)));

	function getAllRobots() view public returns (uint[] memory robots) {
		robots = new uint[](robotIdList.length);
		for(uint i=0; i<robotIdList.length; i++) {
			uint robotId = robotIdList[i];
			robots[2*i] = robotId;
			robots[2*i+1] = robotInfoMap[robotId];
		}
	}

	function loadParams() view public returns (address stock, address money, uint priceDiv, uint priceMul) {
		stock = address(uint160(stock_priceDiv>>96));
		money = address(uint160(money_priceMul>>96));
		priceDiv = uint96(stock_priceDiv);
		priceMul = uint96(money_priceMul);
	}

	function unpackRobotInfo(uint info) pure private returns (uint stockAmount, uint moneyAmount, uint packedPrice) {
		packedPrice = uint(uint64(info));
		moneyAmount = uint(uint96(info>>64));
		stockAmount = uint(uint96(info>>160));
	}

	function packRobotInfo(uint stockAmount, uint moneyAmount, uint packedPrice) pure private returns (uint info) {
		return (stockAmount<<160)|(uint(uint96(moneyAmount))<<64)|packedPrice;
	}

	function unpackPrice(uint packed) pure private returns (uint) {
		uint mask = (1<<25);
		return ((packed&(mask-1))|mask)<<(packed>>24);
	}

	function safeTransfer(address coinType, address receiver, uint amount) internal {
		if(amount == 0) {
			return;
		}
		(bool success, bytes memory data) = coinType.call(
			abi.encodeWithSignature("transfer(address,uint256)", receiver, amount));
		bool ret = abi.decode(data, (bool));
		require(success && ret, "trans-fail");
	}

	function safeReceive(address coinType, uint amount, bool bchExclusive) internal returns (uint96) {
		if(amount == 0) {
			return 0;
		}
		uint realAmount = amount;
		if(coinType == SEP206Contract) {
			require(msg.value == amount, "value-mismatch");
		} else {
			require(!bchExclusive || msg.value == 0, "dont-send-bch");
			uint oldBalance = IERC20(coinType).balanceOf(address(this));
			IERC20(coinType).transferFrom(msg.sender, address(this), uint(amount));
			uint newBalance = IERC20(coinType).balanceOf(address(this));
			realAmount = uint96(newBalance - oldBalance);
		}
		return uint96(realAmount);
	}

	function createRobot(uint robotInfo) external payable {
		(uint stockAmount, uint moneyAmount, uint packedPrice) = unpackRobotInfo(robotInfo);
		require(uint32(packedPrice>>32) > uint32(packedPrice), "invalid-price");
		(address stock, address money, uint priceDiv, uint priceMul) = loadParams();
		bool bchExclusive = stock != SEP206Contract && money != SEP206Contract;
		stockAmount = safeReceive(stock, stockAmount, bchExclusive);
		moneyAmount = safeReceive(money, moneyAmount, bchExclusive);
		uint robotId = uint(uint160(msg.sender))+createdRobotCount;
		createdRobotCount += 1;
		robotIdList.push(robotId);
		robotInfoMap[robotId] = packRobotInfo(stockAmount, moneyAmount, packedPrice);
	}

	function deleteRobot(uint index, uint robotId) external {
		require(msg.sender == address(uint160(robotId>>96)), "not-owner");
		require(robotIdList[index] == robotId, "invalid-index");
		uint last = robotIdList.length - 1;
		if(index != last) {
			robotIdList[index] = robotIdList[last];
		}
		robotIdList.pop();
		uint robotInfo = robotInfoMap[robotId];
		(uint stockAmount, uint moneyAmount, uint packedPrice) = unpackRobotInfo(robotInfo);
		address stock = address(uint160(stock_priceDiv>>96));
		address money = address(uint160(money_priceMul>>96));
		safeTransfer(stock, msg.sender, stockAmount);
		safeTransfer(money, msg.sender, moneyAmount);
	}

	function sellToRobot(uint robotId, uint stockDelta) external payable {
		uint robotInfo = robotInfoMap[robotId];
		require(robotInfo != 0, "robot-not-found");
		(uint stockAmount, uint moneyAmount, uint packedPrice) = unpackRobotInfo(robotInfo);
		uint lowPrice = unpackPrice(uint32(packedPrice));
		(address stock, address money, uint priceDiv, uint priceMul) = loadParams();
		stockDelta = safeReceive(stock, stockAmount, stock != SEP206Contract);
		uint moneyDelta = lowPrice * priceMul * stockDelta / priceDiv;
		require(moneyAmount > moneyDelta, "not-enough-money");
		safeTransfer(money, msg.sender, moneyDelta);
		stockAmount += stockDelta;
		moneyAmount -= moneyDelta;
	}

	function buyFromRobot(uint robotId, uint moneyDelta) external payable {
		uint robotInfo = robotInfoMap[robotId];
		require(robotInfo != 0, "robot-not-found");
		(uint stockAmount, uint moneyAmount, uint packedPrice) = unpackRobotInfo(robotInfo);
		uint highPrice = unpackPrice(packedPrice>>32);
		(address stock, address money, uint priceDiv, uint priceMul) = loadParams();
		moneyDelta = safeReceive(money, moneyAmount, money != SEP206Contract);
		uint stockDelta = moneyDelta * priceDiv / (highPrice * priceMul);
		require(stockAmount > stockDelta, "not-enough-stock");
		safeTransfer(stock, msg.sender, stockDelta);
		stockAmount -= stockDelta;
		moneyAmount += moneyDelta;
	}
}

contract ContinueCashProxy {
	uint public stock_priceDiv;
	uint public money_priceMul;
	uint immutable public implAddr;
	
	constructor(uint _stock_priceDiv, uint _money_priceMul, address _impl) {
		stock_priceDiv = _stock_priceDiv;
		money_priceMul = _money_priceMul;
		implAddr = uint(uint160(bytes20(_impl)));
	}
	
	receive() external payable {
		require(false);
	}

	fallback() payable external {
		uint impl=implAddr;
		assembly {
			let ptr := mload(0x40)
			calldatacopy(ptr, 0, calldatasize())
			let result := delegatecall(gas(), impl, ptr, calldatasize(), 0, 0)
			let size := returndatasize()
			returndatacopy(ptr, 0, size)
			switch result
			case 0 { revert(ptr, size) }
			default { return(ptr, size) }
		}
	}
}

contract ContinueCashFactory {
	address constant SEP206Contract = address(bytes20(uint160(0x2711)));

	event Created(address indexed stock, address indexed money, address pairAddr);

	function create(address stock, address money, address impl) external {
		uint stockDecimals = stock == SEP206Contract ? 18 : IERC20Metadata(stock).decimals();
		uint moneyDecimals = money == SEP206Contract ? 18 : IERC20Metadata(money).decimals();
		uint priceMul = 1;
		uint priceDiv = 1;
		if(moneyDecimals >= stockDecimals) {
			priceMul = (10**(moneyDecimals - stockDecimals));
		} else {
			priceDiv = (10**(stockDecimals - moneyDecimals));
		}
		uint stock_priceDiv = (uint(uint160(stock))<<96)|priceDiv;
		uint money_priceMul = (uint(uint160(money))<<96)|priceMul;

		address pairAddr = address(new ContinueCashProxy{salt: 0}(stock_priceDiv, money_priceMul, impl));
		emit Created(stock, money, pairAddr);
	}
}