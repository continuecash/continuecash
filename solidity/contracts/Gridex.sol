// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// import "hardhat/console.sol";

// Gridex can support the price range from 1/(2**32) to 2**32. The prices within this range is divided to 6400 grids, and 
// the ratio between a pair of adjacent prices is alpha=2**0.01=1.0069555500567189
// A bancor-style market-making pool can be created between a pair of adjacent prices, i.e. priceHi and priceLo.
// Theoretically, there are be 6399 pools. But in pratice, only a few pools with reasonable prices exist.
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

contract GridexLogic {
	uint public stock_priceDiv;
	uint public money_priceMul;

	struct Pool {
		uint96 totalShares;
		uint96 totalStock;
		uint64 soldRatio;
	}

	struct Params {
		address stock;
		address money;
		uint priceDiv;
		uint priceMul;
	}

	address constant private SEP206Contract = address(uint160(0x2711));
	uint constant GridCount = 6400;
	uint constant MaskWordCount = GridCount/256;
	uint constant private RatioBase = 10**19; // need 64 bits
	uint constant private PriceBase = 2**64;
	// alpha = 1.0069555500567189 = 2**0.01;   alpha**100 = 2  2**24=16777216
	// for i in range(10): print((2**24)*(alpha**i))
	uint constant X = (uint(16777216)<<(0*25))| //alpha*0
	                  (uint(16893910)<<(1*25))| //alpha*1
	                  (uint(17011417)<<(2*25))| //alpha*2
	                  (uint(17129740)<<(3*25))| //alpha*3
	                  (uint(17248887)<<(4*25))| //alpha*4
	                  (uint(17368863)<<(5*25))| //alpha*5
	                  (uint(17489673)<<(6*25))| //alpha*6
	                  (uint(17611323)<<(7*25))| //alpha*7
	                  (uint(17733819)<<(8*25))| //alpha*8
	                  (uint(17857168)<<(9*25)); //alpha*9

	// for i in range(10): print((2**24)*(alpha**(i*10)))
	uint constant Y = (uint(16777216)<<(0*25))| //alpha*0
	                  (uint(17981375)<<(1*25))| //alpha*10
	                  (uint(19271960)<<(2*25))| //alpha*20
	                  (uint(20655176)<<(3*25))| //alpha*30
	                  (uint(22137669)<<(4*25))| //alpha*40
	                  (uint(23726566)<<(5*25))| //alpha*50
	                  (uint(25429504)<<(6*25))| //alpha*60
	                  (uint(27254668)<<(7*25))| //alpha*70
	                  (uint(29210830)<<(8*25))| //alpha*80
	                  (uint(31307392)<<(9*25)); //alpha*90

	uint constant MASK25 = (1<<25)-1;
	uint constant Fee = 3;
	uint constant FeeBase = 1000;

	mapping(address => uint128[GridCount]) public userShareMap;
	Pool[GridCount] public pools;
	uint[MaskWordCount] private maskWords;

	function getMaskWords() view external returns (uint[MaskWordCount] memory masks) {
		for(uint i=0; i < masks.length; i++) {
			masks[i] = maskWords[i];
		}
	}

	function getPools(uint start, uint end) view external returns (Pool[] memory poolList) {
		poolList = new Pool[](end-start);
		for(uint i=start; i<end; i++) {
			poolList[i-start] = pools[i];
		}
	}

	function loadParams() view public returns (Params memory params) {
		(params.stock, params.priceDiv) = (address(uint160(stock_priceDiv>>96)), uint96(stock_priceDiv));
		(params.money, params.priceMul) = (address(uint160(money_priceMul>>96)), uint96(money_priceMul));
	}

	function getPrice(uint grid) internal pure returns (uint) {
		require(grid < GridCount, "invalid-grid");
		(uint head, uint tail) = (grid/100, grid%100);
		uint beforeShift = ((Y>>((tail/10)*25))&MASK25) * ((X>>(tail%10)*25)&MASK25);
		if(head>=18) {
			return beforeShift<<(head-18);
		}
		return beforeShift>>(18-head);
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
		{
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
		{
			uint soldStockOld = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			leftStockOld = uint(pool.totalStock)-soldStockOld;
			gotMoneyOld = soldStockOld*(price+priceLo)/(2*PriceBase);
		}

		if(sharesDelta>0) {
			pool.totalStock += uint96(uint(pool.totalStock)*uint(int(sharesDelta))/uint(pool.totalShares));
			pool.totalShares += uint96(sharesDelta);
			userShareMap[msg.sender][grid] += uint128(uint96(sharesDelta));
			pools[grid] = pool;
		} else {
			pool.totalStock -= uint96(uint(pool.totalStock)*uint(int(-sharesDelta))/uint(pool.totalShares));
			pool.totalShares -= uint96(-sharesDelta);
			userShareMap[msg.sender][grid] -= uint128(uint96(-sharesDelta));
			pools[grid] = pool;
		}
		uint leftStockNew;
		uint gotMoneyNew;
		{
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

	function buyFromPools(uint grid, uint stockToBuy, uint maxAveragePrice) public payable 
								returns (uint totalPaidMoney, uint totalGotStock) {
		Params memory params = loadParams();
		(totalPaidMoney, totalGotStock) = (0, 0);
		uint priceHi = getPrice(grid);
		for(; stockToBuy != 0; grid++) {
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
				uint moneyIncr = leftStockOld*(price+priceHi)*(FeeBase+Fee)/(2*FeeBase); //fee in money
				uint gotMoneyNew = gotMoneyOld+moneyIncr;
				uint totalStock = 1/*for rounding error*/+gotMoneyNew*2*PriceBase/(priceHi+priceLo);
				gotMoneyNew = totalStock*(priceHi+priceLo)/(2*PriceBase);
				stockToBuy -= leftStockOld;
				totalGotStock += leftStockOld;
				pool.soldRatio = uint64(RatioBase);
				pool.totalStock = uint96(totalStock);
				totalPaidMoney += gotMoneyNew-gotMoneyOld;
			} else { // cannot buy all in pool
				uint stockFee = stockToBuy*Fee/FeeBase; //fee in stock
				pool.totalStock += uint96(stockFee);
				uint soldStockNew = soldStockOld+stockToBuy;
				pool.soldRatio = uint64(RatioBase*soldStockNew/pool.totalStock);
				price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
				soldStockNew = pool.totalStock*pool.soldRatio/RatioBase;
				uint leftStockNew = pool.totalStock-soldStockNew; 
				                //≈ totalStockOld+stockFee-soldStockOld-stockToBuy
				uint gotMoneyNew = soldStockNew*(price+priceLo)/(2*PriceBase);
				totalGotStock += leftStockOld-leftStockNew; //≈ stockToBuy-stockFee
				totalPaidMoney += gotMoneyNew-gotMoneyOld;
				stockToBuy = 0;
			}
			pools[grid] = pool;
		}
		require(totalPaidMoney*PriceBase <= totalGotStock*maxAveragePrice, "price-too-high");
		safeReceive(params.money, totalPaidMoney, params.money != SEP206Contract);
		safeTransfer(params.stock, msg.sender, totalGotStock);
	}

	function sellToPools(uint grid, uint stockToSell, uint minAveragePrice) public payable 
								returns (uint totalGotMoney, uint totalSoldStock) {
		Params memory params = loadParams();
		(totalGotMoney, totalSoldStock) = (0, 0);
		uint priceLo = getPrice(grid);
		for(; stockToSell != 0; grid--) {
			uint priceHi = priceLo;
			priceLo = getPrice(grid-1);
			Pool memory pool = pools[grid];
			if(pool.totalStock == 0 || pool.soldRatio == 0) { // cannot deal
				continue;
			}
			uint price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
			uint soldStockOld = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			uint leftStockOld = pool.totalStock-soldStockOld;
			uint gotMoneyOld = soldStockOld*(price+priceLo)/(2*PriceBase);
			if(stockToSell*FeeBase >= soldStockOld*(FeeBase+Fee)) { // get all money all in pool
				uint stockFee = soldStockOld*Fee/FeeBase;
				pool.soldRatio = 0;
				pool.totalStock += uint96(stockFee); // fee in stock
				stockToSell -= soldStockOld+stockFee;
				totalSoldStock += soldStockOld+stockFee;
				totalGotMoney += gotMoneyOld;
			} else { // cannot get all money all in pool
				uint stockFee = stockToSell*Fee/FeeBase;
				pool.totalStock += uint96(stockFee); // fee in stock
				uint soldStockNew = soldStockOld-stockToSell;
				pool.soldRatio = uint64(1/*for rounding error*/+RatioBase*soldStockNew/pool.totalStock);
				price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
				soldStockNew = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
				uint leftStockNew = pool.totalStock - soldStockNew;
				               // ≈ totalStockOld+stockFee-soldStockOld+stockToSell
				uint gotMoneyNew = soldStockNew*(price+priceLo)/(2*PriceBase);
				totalSoldStock += leftStockNew-leftStockOld; //≈ stockFee+stockToSell
				totalGotMoney += gotMoneyOld-gotMoneyNew;
				stockToSell = 0;
			}
			pools[grid] = pool;
		}
		require(totalSoldStock*minAveragePrice <= totalGotMoney*PriceBase, "price-too-low");
		safeReceive(params.stock, totalSoldStock, params.stock != SEP206Contract);
		safeTransfer(params.money, msg.sender, totalGotMoney);
	}
}

