// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// import "hardhat/console.sol";

// Gridex can support the price range from 1/(2**32) to 2**32. The prices within this range is divided to 16384 grids, and 
// the ratio between a pair of adjacent prices is alpha=2**(1/256.)=1.0027112750502025
// A bancor-style market-making pool can be created between a pair of adjacent prices, i.e. priceHi and priceLo.
// Theoretically, there are be 16383 pools. But in pratice, only a few pools with reasonable prices exist.
//
//                    * priceHi
//                   /|
//                  / |       priceHi: the high price
//                 /  |       priceLo: the low price
//                /   |       price: current price
//               /    |       sold stock: the stock amount that has been sold out (the a-b line)
//         price*     |       left stock: the stock amount that has NOT been sold out (the b-c line)
//             /|     |       total stock: sum of the sold stock and the left stock (the a-c line)
//            /=|     |       got money: the money mount got by selling stock (the left trapezoid area)
//           /==|     |                  got money = soldStock*(price+priceLo)/2
//          /===|     |       sold ratio = sold stock / total stock
//         /====|     |
// priceLo*=====|     |
//        |=====|     |
//        |=got=|     |
//        |money|     |
//        |=====|_____|
//        a     b     c
//        |sold |left |
//        |stock|stock|
//
// You can deal with a pool by selling stock to it or buying stock from it. And the dealing price is calculated as:
// price = priceLo*(1-soldRatio) + priceHi*soldRatio
// So, if none of the pool's stock is sold, the price is priceLo, if all of the pool's stock is sold, the price is priceHi
// 
// You can add stock and money to a pool to provide more liquidity. The added stock and money must keep the current 
// stock/money ratio of the pool, such that "price" and "soldRatio" are unchanged. After adding you get shares of the pool.
//
// A pool may contains tokens from many different accounts. For each account we record its "shares" amount, which denotes 
// how much of the tokens is owned by this account. For each pool we record its "total shares" amount, which is the sum
// of all the accounts' shares. Shares are like Uniswap-V2's liquidity token. But they are not implemented as ERC20 here.

abstract contract GridexLogicAbstract {
	uint public stock_priceDiv;
	uint public money_priceMul;

	struct Pool {
		uint96 totalShares;
		uint96 totalStock;
		uint64 soldRatio;
	}

	struct PoolWithMyShares {
		uint96 totalShares;
		uint96 totalStock;
		uint64 soldRatio;
		uint96 myShares;
	}

	struct Params {
		address stock;
		address money;
		uint priceDiv;
		uint priceMul;
	}

	address constant private SEP206Contract = address(uint160(0x2711));
	uint constant GridCount = 64*256;
	uint constant MaskWordCount = 64;
	uint constant private RatioBase = 10**19; // need 64 bits
	uint constant private PriceBase = 2**68;
	uint constant MASK16 = (1<<16)-1;
	uint constant FeeBase = 10000;

	mapping(address => uint96[GridCount]) public userShareMap;
	Pool[GridCount] public pools;
	uint[MaskWordCount] internal maskWords;

	function getPrice(uint grid) internal virtual returns (uint);
	function fee() internal virtual returns (uint);
	function getMaskWords() view external virtual returns (uint[] memory masks);

	function getPoolAndMyShares(uint start, uint end) view external returns (PoolWithMyShares[] memory arr) {
		arr = new PoolWithMyShares[](end-start);
		uint96[GridCount] storage myShareArr = userShareMap[msg.sender];
		for(uint i=start; i<end; i++) {
			Pool memory pool = pools[i];
			uint j = i-start;
			arr[j].totalShares = pool.totalShares;
			arr[j].totalStock = pool.totalStock;
			arr[j].soldRatio = pool.soldRatio;
			arr[j].myShares = myShareArr[i];
		}
	}

	function loadParams() view public returns (Params memory params) {
		(params.stock, params.priceDiv) = (address(uint160(stock_priceDiv>>96)), uint96(stock_priceDiv));
		(params.money, params.priceMul) = (address(uint160(money_priceMul>>96)), uint96(money_priceMul));
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

	function safeReceive(address coinType, uint amount, bool bchExclusive) internal {
		if(amount == 0) {
			return;
		}
		if(coinType == SEP206Contract) {
			require(msg.value == amount, "value-mismatch");
		} else {
			require(!bchExclusive || msg.value == 0, "dont-send-bch");
			IERC20(coinType).transferFrom(msg.sender, address(this), uint(amount));
		}
	}

	function initPool(uint grid, uint totalStock, uint soldRatio) public payable returns (uint leftStock, uint gotMoney) {
		require(soldRatio<=RatioBase, "invalid-ration");
		Pool memory pool = pools[grid];
		if(pool.totalShares!=0) {//already created
			return (0, 0);
		}
		pool.totalStock = uint96(totalStock);
		pool.totalShares = uint96(totalStock);
		pool.soldRatio = uint64(soldRatio);
		{ // to avoid "Stack too deep"
			uint priceHi = getPrice(grid+1);
			uint priceLo = getPrice(grid);
			uint soldStock = totalStock*soldRatio/RatioBase;
			leftStock = totalStock-soldStock;
			uint price = (priceHi*soldRatio + priceLo*(RatioBase-soldRatio))/RatioBase;
			gotMoney = soldStock*(price+priceLo)/(2*PriceBase);
			userShareMap[msg.sender][grid] = pool.totalShares;
			pools[grid] = pool;
		}
		address stock = address(uint160(stock_priceDiv>>96));
		address money = address(uint160(money_priceMul>>96));
		bool bchExclusive = stock != SEP206Contract && money != SEP206Contract;
		safeReceive(stock, leftStock, bchExclusive);
		safeReceive(money, gotMoney, bchExclusive);
		(uint wordIdx, uint bitIdx) = (grid/256, grid%256);
		maskWords[wordIdx] |= (uint(1)<<bitIdx); // set bit
	}

	function changeShares(uint grid, int96 sharesDelta) public payable returns (uint, uint) {
		Pool memory pool = pools[grid];
		require(pool.totalShares!=0, "pool-not-init");

		uint priceHi = getPrice(grid+1);
		uint priceLo = getPrice(grid);
		uint price = (priceHi*uint(pool.soldRatio) + priceLo*(RatioBase-uint(pool.soldRatio)))/RatioBase;
		uint leftStockOld;
		uint gotMoneyOld;
		{ // to avoid "Stack too deep"
			uint soldStockOld = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			leftStockOld = uint(pool.totalStock)-soldStockOld;
			gotMoneyOld = soldStockOld*(price+priceLo)/(2*PriceBase);
		}

		if(sharesDelta>0) {
			pool.totalStock += uint96(uint(pool.totalStock)*uint(int(sharesDelta))/uint(pool.totalShares));
			pool.totalShares += uint96(sharesDelta);
			userShareMap[msg.sender][grid] += uint96(sharesDelta);
			pools[grid] = pool;
		} else {
			pool.totalStock -= uint96(uint(pool.totalStock)*uint(int(-sharesDelta))/uint(pool.totalShares));
			pool.totalShares -= uint96(-sharesDelta);
			userShareMap[msg.sender][grid] -= uint96(-sharesDelta);
			pools[grid] = pool;
		}
		uint leftStockNew;
		uint gotMoneyNew;
		{ // to avoid "Stack too deep"
			uint soldStockNew = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			leftStockNew = uint(pool.totalStock)-soldStockNew;
			gotMoneyNew = soldStockNew*(price+priceLo)/(2*PriceBase);
		}

		address stock = address(uint160(stock_priceDiv>>96));
		address money = address(uint160(money_priceMul>>96));
		bool bchExclusive = stock != SEP206Contract && money != SEP206Contract;
		if(sharesDelta>0) {
			uint deltaStock = leftStockNew-leftStockOld;
			uint deltaMoney = gotMoneyNew-gotMoneyOld;
			safeReceive(stock, deltaStock, bchExclusive);
			safeReceive(money, deltaMoney, bchExclusive);
			return (deltaStock, deltaMoney);
		} else {
			uint deltaStock = leftStockOld-leftStockNew;
			uint deltaMoney = gotMoneyOld-gotMoneyNew;
			safeTransfer(stock, msg.sender, deltaStock);
			safeTransfer(money, msg.sender, deltaMoney);
			return (deltaStock, deltaMoney);
		}
	}

	function buyFromPools(uint grid, uint stockToBuy, uint maxAveragePrice_stopGrid) public payable 
								returns (uint totalPaidMoney, uint totalGotStock) {
		Params memory params = loadParams();
		(totalPaidMoney, totalGotStock) = (0, 0);
		uint priceHi = getPrice(grid);
		uint fee_ = fee();
		for(; stockToBuy != 0 && grid < uint16(maxAveragePrice_stopGrid); grid++) {
			uint priceLo = priceHi;
			priceHi = getPrice(grid+1);
			Pool memory pool = pools[grid];
			if(pool.totalStock == 0 || pool.soldRatio == RatioBase) { // cannot deal
				continue;
			}
			uint price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
			uint soldStockOld = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			uint leftStockOld = uint(pool.totalStock)-soldStockOld;
			uint gotMoneyOld = soldStockOld*(price+priceLo)/(2*PriceBase);
			if(stockToBuy >= leftStockOld) { // buy all in pool
				uint gotMoneyNew = gotMoneyOld+
				    /*MoneyIncr:*/ leftStockOld*(price+priceHi)*(FeeBase+fee_)/(2*FeeBase); //fee in money
				uint totalStock = 1/*for rounding error*/+gotMoneyNew*2*PriceBase/(priceHi+priceLo);
				gotMoneyNew = totalStock*(priceHi+priceLo)/(2*PriceBase);
				stockToBuy -= leftStockOld;
				totalGotStock += leftStockOld;
				pool.soldRatio = uint64(RatioBase);
				pool.totalStock = uint96(totalStock);
				totalPaidMoney += gotMoneyNew-gotMoneyOld;
			} else { // cannot buy all in pool
				uint stockFee = stockToBuy*fee_/FeeBase; //fee in stock
				pool.totalStock += uint96(stockFee);
				uint soldStockNew = soldStockOld+stockToBuy;
				pool.soldRatio = uint64(RatioBase*soldStockNew/pool.totalStock);
				price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
				soldStockNew = pool.totalStock*pool.soldRatio/RatioBase;
				{ // to avoid "Stack too deep"
				uint leftStockNew = pool.totalStock-soldStockNew; 
				                //≈ totalStockOld+stockFee-soldStockOld-stockToBuy
				uint gotMoneyNew = soldStockNew*(price+priceLo)/(2*PriceBase);
				totalGotStock += leftStockOld-leftStockNew; //≈ stockToBuy-stockFee
				totalPaidMoney += gotMoneyNew-gotMoneyOld;
				} // to avoid "Stack too deep"
				stockToBuy = 0;
			}
			pools[grid] = pool;
		}
		require(totalPaidMoney*PriceBase <= totalGotStock*(maxAveragePrice_stopGrid>>16), "price-too-high");
		safeReceive(params.money, totalPaidMoney, params.money != SEP206Contract);
		safeTransfer(params.stock, msg.sender, totalGotStock);
	}

	function sellToPools(uint grid, uint stockToSell, uint minAveragePrice_stopGrid) public payable 
								returns (uint totalGotMoney, uint totalSoldStock) {
		Params memory params = loadParams();
		(totalGotMoney, totalSoldStock) = (0, 0);
		uint priceLo = getPrice(grid);
		uint fee_ = fee();
		for(; stockToSell != 0 && grid>uint16(minAveragePrice_stopGrid); grid--) {
			uint priceHi = priceLo;
			priceLo = getPrice(grid-1);
			Pool memory pool = pools[grid];
			if(pool.totalStock == 0 || pool.soldRatio == 0) { // cannot deal
				continue;
			}
			{ // to avoid "Stack too deep"
			uint price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
			uint soldStockOld = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			uint leftStockOld = pool.totalStock-soldStockOld;
			uint gotMoneyOld = soldStockOld*(price+priceLo)/(2*PriceBase);
			uint stockFee = soldStockOld*fee_/FeeBase;
			if(stockToSell >= soldStockOld+stockFee) { // get all money all in pool
				pool.soldRatio = 0;
				pool.totalStock += uint96(stockFee); // fee in stock
				stockToSell -= soldStockOld+stockFee;
				totalSoldStock += soldStockOld+stockFee;
				totalGotMoney += gotMoneyOld;
			} else { // cannot get all money all in pool
				stockFee = stockToSell*fee_/FeeBase;
				pool.totalStock += uint96(stockFee); // fee in stock
				{ // to avoid "Stack too deep"
				uint soldStockNew = soldStockOld-stockToSell;
				pool.soldRatio = uint64(1/*for rounding error*/+RatioBase*soldStockNew/pool.totalStock);
				price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
				soldStockNew = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
				uint leftStockNew = pool.totalStock - soldStockNew;
				               // ≈ totalStockOld+stockFee-soldStockOld+stockToSell
				uint gotMoneyNew = soldStockNew*(price+priceLo)/(2*PriceBase);
				totalSoldStock += leftStockNew-leftStockOld; //≈ stockFee+stockToSell
				totalGotMoney += gotMoneyOld-gotMoneyNew;
				} // to avoid "Stack too deep"
				stockToSell = 0;
			}
			} // to avoid "Stack too deep"
			pools[grid] = pool;
		}
		require(totalSoldStock*(minAveragePrice_stopGrid>>16) <= totalGotMoney*PriceBase, "price-too-low");
		safeReceive(params.stock, totalSoldStock, params.stock != SEP206Contract);
		safeTransfer(params.money, msg.sender, totalGotMoney);
	}
}

contract GridexLogic256 is GridexLogicAbstract {
	// alpha = 1.0027112750502025 = 2**(1/256.);   alpha**256 = 2  2**16=65536
	// for i in range(16): print(round((2**20)*(alpha**i)))
	uint constant X = (uint(1048576-1048576)<< 0)| // 2**20 * (alpha**0-1)
                          (uint(1051419-1048576)<< 1)| // 2**20 * (alpha**1-1)
                          (uint(1054270-1048576)<< 2)| // 2**20 * (alpha**2-1)
                          (uint(1057128-1048576)<< 3)| // 2**20 * (alpha**3-1)
                          (uint(1059994-1048576)<< 4)| // 2**20 * (alpha**4-1)
                          (uint(1062868-1048576)<< 5)| // 2**20 * (alpha**5-1)
                          (uint(1065750-1048576)<< 6)| // 2**20 * (alpha**6-1)
                          (uint(1068639-1048576)<< 7)| // 2**20 * (alpha**7-1)
                          (uint(1071537-1048576)<< 8)| // 2**20 * (alpha**8-1)
                          (uint(1074442-1048576)<< 9)| // 2**20 * (alpha**9-1)
                          (uint(1077355-1048576)<<10)| // 2**20 * (alpha**10-1)
                          (uint(1080276-1048576)<<11)| // 2**20 * (alpha**11-1)
                          (uint(1083205-1048576)<<12)| // 2**20 * (alpha**12-1)
                          (uint(1086142-1048576)<<13)| // 2**20 * (alpha**13-1)
                          (uint(1089087-1048576)<<14)| // 2**20 * (alpha**14-1)
                          (uint(1092040-1048576)<<15); // 2**20 * (alpha**15-1)

	// for i in range(16): print(round((2**16)*(alpha**(i*16))))
	uint constant Y = (uint(65536 -65536)<<( 0*16))| // 2**16 * (alpha**(0*16 )-1)
                          (uint(68438 -65536)<<( 1*16))| // 2**16 * (alpha**(1*16 )-1)
                          (uint(71468 -65536)<<( 2*16))| // 2**16 * (alpha**(2*16 )-1)
                          (uint(74632 -65536)<<( 3*16))| // 2**16 * (alpha**(3*16 )-1)
                          (uint(77936 -65536)<<( 4*16))| // 2**16 * (alpha**(4*16 )-1)
                          (uint(81386 -65536)<<( 5*16))| // 2**16 * (alpha**(5*16 )-1)
                          (uint(84990 -65536)<<( 6*16))| // 2**16 * (alpha**(6*16 )-1)
                          (uint(88752 -65536)<<( 7*16))| // 2**16 * (alpha**(7*16 )-1)
                          (uint(92682 -65536)<<( 8*16))| // 2**16 * (alpha**(8*16 )-1)
                          (uint(96785 -65536)<<( 9*16))| // 2**16 * (alpha**(9*16 )-1)
                          (uint(101070-65536)<<(10*16))| // 2**16 * (alpha**(10*16)-1)
                          (uint(105545-65536)<<(11*16))| // 2**16 * (alpha**(11*16)-1)
                          (uint(110218-65536)<<(12*16))| // 2**16 * (alpha**(12*16)-1)
                          (uint(115098-65536)<<(13*16))| // 2**16 * (alpha**(13*16)-1)
                          (uint(120194-65536)<<(14*16))| // 2**16 * (alpha**(14*16)-1)
                          (uint(125515-65536)<<(15*16)); // 2**16 * (alpha**(15*16)-1)

	function getPrice(uint grid) internal pure override returns (uint) {
		require(grid < GridCount, "invalid-grid");
		(uint head, uint tail) = (grid/256, grid%256);
		uint beforeShift = (2**20+((X>>((tail%16)*16))&MASK16)) * (2**16+((Y>>(tail/16)*16)&MASK16));
		return beforeShift<<head;
	}

	function fee() internal pure override returns (uint) {
		return 5;
	}

	function getMaskWords() view external override returns (uint[] memory masks) {
		masks = new uint[](MaskWordCount);
		for(uint i=0; i < masks.length; i++) {
			masks[i] = maskWords[i];
		}
	}
}

contract GridexLogic64 is GridexLogicAbstract {
	// alpha = 1.0108892860517005 = 2**(1/64.);   alpha**256 = 2  2**19=524288
	// for i in range(8): print(round((2**19)*(alpha**i)))
	uint constant X = (uint(524288-524288)<< 0)| // 2**19 * (alpha**0 - 1)
                          (uint(529997-524288)<< 1)| // 2**19 * (alpha**1 - 1)
                          (uint(535768-524288)<< 2)| // 2**19 * (alpha**2 - 1)
                          (uint(541603-524288)<< 3)| // 2**19 * (alpha**3 - 1)
                          (uint(547500-524288)<< 4)| // 2**19 * (alpha**4 - 1)
                          (uint(553462-524288)<< 5)| // 2**19 * (alpha**5 - 1)
                          (uint(559489-524288)<< 6)| // 2**19 * (alpha**6 - 1)
                          (uint(565581-524288)<< 7); // 2**19 * (alpha**7 - 1)

	// for i in range(8): print(round((2**16)*(alpha**(i*8))))
	uint constant Y = (uint(65536 -65536)<< 0)| // 2**16 * (alpha**(0*8)-1)
                          (uint(71468 -65536)<< 1)| // 2**16 * (alpha**(1*8)-1)
                          (uint(77936 -65536)<< 2)| // 2**16 * (alpha**(2*8)-1)
                          (uint(84990 -65536)<< 3)| // 2**16 * (alpha**(3*8)-1)
                          (uint(92682 -65536)<< 4)| // 2**16 * (alpha**(4*8)-1)
                          (uint(101070-65536)<< 5)| // 2**16 * (alpha**(5*8)-1)
                          (uint(110218-65536)<< 6)| // 2**16 * (alpha**(6*8)-1)
                          (uint(120194-65536)<< 7); // 2**16 * (alpha**(7*8)-1)

	function getPrice(uint grid) internal pure override returns (uint) {
		require(grid < GridCount, "invalid-grid");
		(uint head, uint tail) = (grid/64, grid%64);
		uint beforeShift = (2**19+((X>>((tail%8)*16))&MASK16)) * (2**16+((Y>>(tail/8)*16)&MASK16));
		return beforeShift<<(1+head);
	}

	function fee() internal pure override returns (uint) {
		return 30;
	}

	function getMaskWords() view external override returns (uint[] memory masks) {
		masks = new uint[](MaskWordCount/8);
		for(uint i=0; i < masks.length; i++) {
			masks[i] = maskWords[i];
		}
	}
}

contract GridexProxy {
	uint public stock_priceDiv;
	uint public money_priceMul;
	uint immutable public implAddr;
	
	constructor(uint _stock_priceDiv, uint _money_priceMul, address _impl) {
		stock_priceDiv = _stock_priceDiv;
		money_priceMul = _money_priceMul;
		implAddr = uint(uint160(_impl));
	}
	
	receive() external payable {
		require(false);
	}

	fallback() external payable {
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

contract GridexFactory {
	address constant SEP206Contract = address(uint160(0x2711));

	event Created(address indexed stock, address indexed money, address indexed impl, address pairAddr);

	function getAddress(address stock, address money, address impl) public view returns (address) {
		bytes memory bytecode = type(GridexProxy).creationCode;
		(uint stock_priceDiv, uint money_priceMul) = getParams(stock, money);
		bytes32 codeHash = keccak256(abi.encodePacked(bytecode, abi.encode(
			stock_priceDiv, money_priceMul, impl)));
		bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), codeHash));
		return address(uint160(uint(hash)));
	}

	function getParams(address stock, address money) private view returns (uint stock_priceDiv, uint money_priceMul) {
		uint stockDecimals = stock == SEP206Contract ? 18 : IERC20Metadata(stock).decimals();
		uint moneyDecimals = money == SEP206Contract ? 18 : IERC20Metadata(money).decimals();
		uint priceMul = 1;
		uint priceDiv = 1;
		if(moneyDecimals >= stockDecimals) {
			priceMul = (10**(moneyDecimals - stockDecimals));
		} else {
			priceDiv = (10**(stockDecimals - moneyDecimals));
		}
		stock_priceDiv = (uint(uint160(stock))<<96)|priceDiv;
		money_priceMul = (uint(uint160(money))<<96)|priceMul;
	}

	function create(address stock, address money, address impl) external {
		(uint stock_priceDiv, uint money_priceMul) = getParams(stock, money);
		address pairAddr = address(new GridexProxy{salt: 0}(stock_priceDiv, money_priceMul, impl));
		emit Created(stock, money, impl, pairAddr);
	}
}
