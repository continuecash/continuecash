const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");

describe("ContinueCash", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshopt in every test.
  async function deployFixture() {
    const Logic = await ethers.getContractFactory("ContinueCashLogic");
    const logic = await Logic.deploy();
    // console.log('logic addr:', logic.address);

    const Factory = await ethers.getContractFactory("ContinueCashFactory");
    const factory = await Factory.deploy();
    // console.log('factory addr:', factory.address);

    const ERC20ForTest = await ethers.getContractFactory("ERC20ForTest");
    const wBCH = await ERC20ForTest.deploy("wBCH", ethers.utils.parseUnits('10000000', 18), 18);
    const fUSD = await ERC20ForTest.deploy("fUSD", ethers.utils.parseUnits('10000000',  8),  8);
    const gUSD = await ERC20ForTest.deploy("gUSD", ethers.utils.parseUnits('10000000', 18), 18);
    const hUSD = await ERC20ForTest.deploy("hUSD", ethers.utils.parseUnits('10000000', 20), 20);
    // console.log('wBCH addr:', wBCH.address);
    // console.log('fUSD addr:', fUSD.address);
    // console.log('gUSD addr:', gUSD.address);
    // console.log('hUSD addr:', hUSD.address);

    return {Logic, logic, factory, wBCH, fUSD, gUSD, hUSD};
  }

  describe("ContinueCashFactory", function () {

    it("getAddress", async function () {
      const { _, logic, factory, wBCH, fUSD } = await loadFixture(deployFixture);
      const proxyAddr = await factory.getAddress(wBCH.address, fUSD.address, logic.address);
      // console.log(proxyAddr);

      await expect(factory.create(wBCH.address, fUSD.address, logic.address))
        .to.emit(factory, "Created")
        .withArgs(wBCH.address, fUSD.address, proxyAddr);
    });

  });

  describe("ContinueCashLogic: getParams", function () {
  
    it("getParams", async function () {
      const { Logic, logic, factory, wBCH, fUSD, gUSD, hUSD } = await loadFixture(deployFixture);

      [
        [fUSD.address, ethers.BigNumber.from(1e10), ethers.BigNumber.from(  1)],
        [gUSD.address, ethers.BigNumber.from(   1), ethers.BigNumber.from(  1)],
        [hUSD.address, ethers.BigNumber.from(   1), ethers.BigNumber.from(100)],
      ].forEach(async (params) => {
        await factory.create(wBCH.address, params[0], logic.address);
        const proxyAddr = await factory.getAddress(wBCH.address, params[0], logic.address);
        const proxy = await Logic.attach(proxyAddr);
        expect(await proxy.loadParams()).to.deep.equal([
          wBCH.address, params[0], params[1], params[2],
        ]);
      });
    });

  });

  describe("ContinueCashLogic: create/deleteRobot", function () {

    let owner, acc1;
    let wBCH, fUSD;
    let proxy;

    beforeEach(async function () {
      [owner, acc1] = await ethers.getSigners();

      const fixture = await loadFixture(deployFixture);
      let {Logic, logic, factory } = fixture;
      [wBCH, fUSD] = [fixture.wBCH, fixture.fUSD];

      await factory.create(wBCH.address, fUSD.address, logic.address);
      const proxyAddr = await factory.getAddress(wBCH.address, fUSD.address, logic.address);
      proxy = await Logic.attach(proxyAddr);
    });

    it("createRobot: invalid-price", async function () {
      await expect(proxy.createRobot(packRobotInfo(123n, 456n, 789n, 987n)))
        .to.be.revertedWith("invalid-price");
    });

    it("createRobot: dont-send-bch", async function () {
      await expect(proxy.createRobot(packRobotInfo(123n, 456n, 789n, 678n), {value: 100}))
        .to.be.revertedWith("dont-send-bch");
    });

    it("createRobot: insufficient allowance", async function () {
      await expect(proxy.createRobot(packRobotInfo(123n, 456n, 789n, 678n)))
        .to.be.revertedWith("ERC20: insufficient allowance");

      await wBCH.approve(proxy.address, 123n);
      await expect(proxy.createRobot(packRobotInfo(123n, 456n, 789n, 678n)))
        .to.be.revertedWith("ERC20: insufficient allowance");

      await fUSD.approve(proxy.address, 456n);
      await proxy.createRobot(packRobotInfo(123n, 456n, 789n, 678n));
      expect(await wBCH.balanceOf(proxy.address)).to.be.equal(123);
      expect(await fUSD.balanceOf(proxy.address)).to.be.equal(456);
    });

    it("deleteRobot: not-owner", async function () {
      await wBCH.approve(proxy.address, 999999999n);
      await fUSD.approve(proxy.address, 999999999n);
      await proxy.createRobot(packRobotInfo(400n, 300n, 200n, 100n));

      const robotId0 = encodeRobotId(owner.address, 0);
      await expect(proxy.connect(acc1).deleteRobot(0, robotId0))
        .to.be.revertedWith("not-owner");
    });

    it("deleteRobot: invalid-index", async function () {
      await wBCH.approve(proxy.address, 999999999n);
      await fUSD.approve(proxy.address, 999999999n);
      await proxy.createRobot(packRobotInfo(400n, 300n, 200n, 100n));
      await proxy.createRobot(packRobotInfo(401n, 301n, 201n, 101n));

      const robotId = encodeRobotId(owner.address, 0);
      await expect(proxy.deleteRobot(1, robotId))
        .to.be.revertedWith("invalid-index");
    });

    it("deleteRobot: return coins", async function () {
      await wBCH.transfer(acc1.address, 10000n);
      await fUSD.transfer(acc1.address, 10000n);
      await wBCH.connect(acc1).approve(proxy.address, 999999999n);
      await fUSD.connect(acc1).approve(proxy.address, 999999999n);
      await proxy.connect(acc1).createRobot(packRobotInfo(1000n, 2000n, 200n, 100n));
      expect(await wBCH.balanceOf(acc1.address)).to.be.equal(9000n);
      expect(await fUSD.balanceOf(acc1.address)).to.be.equal(8000n);

      const robotId0 = encodeRobotId(acc1.address, 0);
      await proxy.connect(acc1).deleteRobot(0, robotId0);

      expect(await wBCH.balanceOf(acc1.address)).to.be.equal(10000n);
      expect(await fUSD.balanceOf(acc1.address)).to.be.equal(10000n);
    });

    it("create/deleteRobot: storage", async function () {
      await wBCH.approve(proxy.address, 999999999n);
      await fUSD.approve(proxy.address, 999999999n);

      const robotId0 = encodeRobotId(owner.address, 0);
      const robotId1 = encodeRobotId(owner.address, 1);
      const robotId2 = encodeRobotId(owner.address, 2);
      const robotId3 = encodeRobotId(owner.address, 3);

      const robotInfo0 = packRobotInfo(400n, 300n, 200n, 100n);
      const robotInfo1 = packRobotInfo(401n, 301n, 201n, 101n);
      const robotInfo2 = packRobotInfo(402n, 302n, 202n, 102n);
      const robotInfo3 = packRobotInfo(403n, 303n, 203n, 103n);

      await proxy.createRobot(robotInfo0);
      await proxy.createRobot(robotInfo1);
      await proxy.createRobot(robotInfo2);
      await proxy.createRobot(robotInfo3);

      expect(await proxy.createdRobotCount()).to.be.equal(4);
      expect(await loadAllRobots(proxy)).to.deep.equal([
        {id: robotId0, info: robotInfo0},
        {id: robotId1, info: robotInfo1},
        {id: robotId2, info: robotInfo2},
        {id: robotId3, info: robotInfo3},
      ]);

      await proxy.deleteRobot(0, robotId0);
      expect(await loadAllRobots(proxy)).to.deep.equal([
        {id: robotId3, info: robotInfo3},
        {id: robotId1, info: robotInfo1},
        {id: robotId2, info: robotInfo2},
      ]);

      await proxy.deleteRobot(1, robotId1);
      expect(await loadAllRobots(proxy)).to.deep.equal([
        {id: robotId3, info: robotInfo3},
        {id: robotId2, info: robotInfo2},
      ]);

      await proxy.deleteRobot(1, robotId2);
      expect(await loadAllRobots(proxy)).to.deep.equal([
        {id: robotId3, info: robotInfo3},
      ]);

      await proxy.deleteRobot(0, robotId3);
      expect(await loadAllRobots(proxy)).to.deep.equal([
      ]);
    });

  });

  describe("ContinueCashLogic: sellTo/buyFromRobot", function () {
    let owner, taker;
    let wBCH, fUSD;
    let proxy;
    let robotId0, robotId1;

    beforeEach(async function () {
      [owner, taker] = await ethers.getSigners();

      const fixture = await loadFixture(deployFixture);
      let {Logic, logic, factory } = fixture;
      [wBCH, fUSD] = [fixture.wBCH, fixture.fUSD];

      await factory.create(wBCH.address, fUSD.address, logic.address);
      const proxyAddr = await factory.getAddress(wBCH.address, fUSD.address, logic.address);
      proxy = await Logic.attach(proxyAddr);
      proxy.stockDec = 18; //wBCH;
      proxy.moneyDec =  8; //fUSD;

      await wBCH.approve(proxy.address, 99999n * 10n**18n);
      await fUSD.approve(proxy.address, 99999n * 10n**8n);

      robotId0 = encodeRobotId(owner.address, 0);
      robotId1 = encodeRobotId(owner.address, 1);

      const robotInfo0 = packRobotInfo(
        100n * 10n**18n,
        500n * 10n**8n,
        '150.0', 
        '100.0',
      );
      await proxy.createRobot(robotInfo0);

      await wBCH.transfer(taker.address, 200n * 10n**18n);
      await fUSD.transfer(taker.address, 20000n * 10n**8n);

      expect(await wBCH.balanceOf(proxy.address)).to.be.equal(100n * 10n**18n);
      expect(await fUSD.balanceOf(proxy.address)).to.be.equal(500n * 10n**8n);
      expect(await wBCH.balanceOf(taker.address)).to.be.equal(200n * 10n**18n);
      expect(await fUSD.balanceOf(taker.address)).to.be.equal(20000n * 10n**8n);
    });

    it("sellToRobot: no-approve", async function () {
      await expect(proxy.connect(taker).sellToRobot(robotId0, 123))
        .to.be.revertedWith("ERC20: insufficient allowance");
    });
    it("buyFromRobot: no-approve", async function () {
      await expect(proxy.connect(taker).buyFromRobot(robotId0, 123))
        .to.be.revertedWith("ERC20: insufficient allowance");
    });

    it("sellToRobot: robot-not-found", async function () {
      await wBCH.connect(taker).approve(proxy.address, 99999n * 10n**18n);
      await expect(proxy.connect(taker).sellToRobot(robotId1, 123))
        .to.be.revertedWith("robot-not-found");
    });
    it("buyFromRobot: robot-not-found", async function () {
      await fUSD.connect(taker).approve(proxy.address, 99999n * 10n**8n);
      await expect(proxy.connect(taker).buyFromRobot(robotId1, 123))
        .to.be.revertedWith("robot-not-found");
    });

    it("sellToRobot: not-enough-money", async function () {
      await wBCH.connect(taker).approve(proxy.address, 99999n * 10n**18n);
      await expect(proxy.connect(taker).sellToRobot(robotId0, 100n * 10n**18n))
        .to.be.revertedWith("not-enough-money");
    });
    it("buyFromRobot: not-enough-stock", async function () {
      await fUSD.connect(taker).approve(proxy.address, 99999n * 10n**8n);
      await expect(proxy.connect(taker).buyFromRobot(robotId0, 20000n * 10n**8n))
        .to.be.revertedWith("not-enough-stock");
    });

    it("sellToRobot: ok", async function () {
      await wBCH.connect(taker).approve(proxy.address, 99999n * 10n**18n);
      await proxy.connect(taker).sellToRobot(robotId0, 1n * 10n**18n);

      expect(await getRobotById(proxy, robotId0)).to.deep.equal({
        stockAmount: "101.0",
        moneyAmount: "400.0000024",
        highPrice: "149.9999942100385792",
        lowPrice: "99.999997606041223168",
      });

      expect(ethers.utils.formatUnits(await wBCH.balanceOf(proxy.address), 18)).to.be.equal("101.0");
      expect(ethers.utils.formatUnits(await fUSD.balanceOf(proxy.address),  8)).to.be.equal("400.0000024");
      expect(ethers.utils.formatUnits(await wBCH.balanceOf(taker.address), 18)).to.be.equal("199.0");
      expect(ethers.utils.formatUnits(await fUSD.balanceOf(taker.address),  8)).to.be.equal("20099.9999976");
    });
    it("buyFromRobot: ok", async function () {
      await fUSD.connect(taker).approve(proxy.address, 99999n * 10n**8n);
      await proxy.connect(taker).buyFromRobot(robotId0, 300n * 10n**8n);
      expect(await getRobotById(proxy, robotId0)).to.deep.equal({
        stockAmount: "97.99999992280051141",
        moneyAmount: "800.0",
        highPrice: "149.9999942100385792",
        lowPrice: "99.999997606041223168",
      });

      expect(ethers.utils.formatUnits(await wBCH.balanceOf(proxy.address), 18)).to.be.equal("97.99999992280051141");
      expect(ethers.utils.formatUnits(await fUSD.balanceOf(proxy.address),  8)).to.be.equal("800.0");
      expect(ethers.utils.formatUnits(await wBCH.balanceOf(taker.address), 18)).to.be.equal("202.00000007719948859");
      expect(ethers.utils.formatUnits(await fUSD.balanceOf(taker.address),  8)).to.be.equal("19700.0");
    });

  });

  describe("ContinueCashLogic: money has more decimals", function () {
    let owner, taker;
    let wBCH, hUSD;
    let proxy;
    let robotId0, robotId1;

    beforeEach(async function () {
      [owner, taker] = await ethers.getSigners();

      const fixture = await loadFixture(deployFixture);
      let {Logic, logic, factory } = fixture;
      [wBCH, hUSD] = [fixture.wBCH, fixture.hUSD];

      await factory.create(wBCH.address, hUSD.address, logic.address);
      const proxyAddr = await factory.getAddress(wBCH.address, hUSD.address, logic.address);
      proxy = await Logic.attach(proxyAddr);
      proxy.stockDec = 18; //wBCH;
      proxy.moneyDec = 20; //hUSD;

      await wBCH.approve(proxy.address, 99999n * 10n**18n);
      await hUSD.approve(proxy.address, 99999n * 10n**20n);

      robotId0 = encodeRobotId(owner.address, 0);
      robotId1 = encodeRobotId(owner.address, 1);

      const robotInfo0 = packRobotInfo(
        100n * 10n**18n,
        500n * 10n**20n,
        '150.0', 
        '100.0',
      );
      await proxy.createRobot(robotInfo0);

      await wBCH.transfer(taker.address, 200n * 10n**18n);
      await hUSD.transfer(taker.address, 20000n * 10n**20n);

      expect(await wBCH.balanceOf(proxy.address)).to.be.equal(100n * 10n**18n);
      expect(await hUSD.balanceOf(proxy.address)).to.be.equal(500n * 10n**20n);
      expect(await wBCH.balanceOf(taker.address)).to.be.equal(200n * 10n**18n);
      expect(await hUSD.balanceOf(taker.address)).to.be.equal(20000n * 10n**20n);
    });

    it("sellToRobot: ok", async function () {
      await wBCH.connect(taker).approve(proxy.address, 99999n * 10n**18n);
      await proxy.connect(taker).sellToRobot(robotId0, 1n * 10n**18n);

      expect(await getRobotById(proxy, robotId0)).to.deep.equal({
        stockAmount: "101.0",
        moneyAmount: "400.000002393958776832",
        highPrice: "149.9999942100385792",
        lowPrice: "99.999997606041223168",
      });

      expect(ethers.utils.formatUnits(await wBCH.balanceOf(proxy.address), 18)).to.be.equal("101.0");
      expect(ethers.utils.formatUnits(await hUSD.balanceOf(proxy.address), 20)).to.be.equal("400.000002393958776832");
      expect(ethers.utils.formatUnits(await wBCH.balanceOf(taker.address), 18)).to.be.equal("199.0");
      expect(ethers.utils.formatUnits(await hUSD.balanceOf(taker.address), 20)).to.be.equal("20099.999997606041223168");
    });
    it("buyFromRobot: ok", async function () {
      await hUSD.connect(taker).approve(proxy.address, 99999n * 10n**20n);
      await proxy.connect(taker).buyFromRobot(robotId0, 300n * 10n**20n);
      expect(await getRobotById(proxy, robotId0)).to.deep.equal({
        stockAmount: "97.99999992280051141",
        moneyAmount: "800.0",
        highPrice: "149.9999942100385792",
        lowPrice: "99.999997606041223168",
      });

      expect(ethers.utils.formatUnits(await wBCH.balanceOf(proxy.address), 18)).to.be.equal("97.99999992280051141");
      expect(ethers.utils.formatUnits(await hUSD.balanceOf(proxy.address), 20)).to.be.equal("800.0");
      expect(ethers.utils.formatUnits(await wBCH.balanceOf(taker.address), 18)).to.be.equal("202.00000007719948859");
      expect(ethers.utils.formatUnits(await hUSD.balanceOf(taker.address), 20)).to.be.equal("19700.0");
    });

  });

});


function packRobotInfo(stockAmount, moneyAmount, highPrice, lowPrice) {
  return (stockAmount << 160n)
       | (moneyAmount <<  64n)
       | packPriceX(highPrice) << 32n | packPriceX(lowPrice);
}
function encodeRobotId(addr, createdRobotCount) {
  return (BigInt(addr) << 96n) + BigInt(createdRobotCount);
}

async function getRobotById(proxy, robotId) {
  const robotInfo = await proxy.robotInfoMap(robotId);
  const robotInfoN = BigInt(robotInfo.toString());
  return {
    stockAmount: ethers.utils.formatUnits(robotInfoN >> 160n, proxy.stockDec),
    moneyAmount: ethers.utils.formatUnits((robotInfoN >> 64n) & 0xFFFFFFFFFFFFFFFFFFFFFFFFn, proxy.moneyDec),
    highPrice  : ethers.utils.formatUnits(unpackPriceN((robotInfoN >> 32n) & 0xFFFFFFFFn), 18),
    lowPrice   : ethers.utils.formatUnits(unpackPriceN(robotInfoN & 0xFFFFFFFFn), 18),
  };
}

async function loadAllRobots(proxy) {
  const robots = [];

  const idAndInfoArr = await proxy.getAllRobots();
  for (let i = 0; i < idAndInfoArr.length; i+=2) {
    robots.push({
      id: BigInt(idAndInfoArr[i].toHexString()),
      info: idAndInfoArr[i + 1],
    });
  }

  return robots;
}

function packPriceX(price) {
  switch (typeof price) {
    case 'bigint': return BigInt(packPrice(ethers.BigNumber.from(price * 10n**18n)).toString());
    case 'string': return BigInt(packPrice(ethers.utils.parseUnits(price, 18)).toString());
    default: throw "invalid price: " + price;
  }
}
function unpackPriceN(price) {
  return unpackPrice(ethers.BigNumber.from(price));
}

function packPrice(price) {
	var effBits = 1
	while(!price.mask(effBits).eq(price)) {
		effBits += 1
	}
	var twoPow24 = ethers.BigNumber.from(2).pow(24)
	if(effBits <= 25) {
		return price
	}
	var shift = effBits-25
	var shiftBN = ethers.BigNumber.from(2).pow(shift)
	var low24 = price.div(shiftBN).sub(twoPow24)
	var high8 = ethers.BigNumber.from(shift).add(1).mul(twoPow24)
	return high8.add(low24)
}

function unpackPrice(packed) {
	var twoPow24 = ethers.BigNumber.from(2).pow(24)
	var low24 = packed.mod(twoPow24)
	var shift = packed.div(twoPow24)
	if(shift.isZero()) {
		return low24
	}
	var shiftBN = ethers.BigNumber.from(2).pow(shift.sub(1))
	return low24.add(twoPow24).mul(shiftBN)
}

function testPackPrice() {
	function test(origin) {
		console.log("origin", origin.toHexString())
		console.log("packed", packPrice(origin).toHexString())
		console.log("unpack", unpackPrice(packPrice(origin)).toHexString())
	}

	test(ethers.BigNumber.from("0xF"))
	test(ethers.BigNumber.from("0xF00123"))
	test(ethers.BigNumber.from("0x1F00123"))
	test(ethers.BigNumber.from("0x10101010101010101"))
	test(ethers.BigNumber.from("0x1234567890ABCDEF"))
	test(ethers.BigNumber.from("0x1234567890ABCDEF1234567890ABCDEF"))
}

function testPackPrice2() {
  [
    "0.0000000001",
    "0.0000000012",
    "0.0000000123",
    "0.0000001234",
    "0.0000012345",
    "0.000012345",
    "0.000123456",
    "0.001234567",
    "0.012345678",
    "0.123456789",
    "1.234567890",
    "12.34567890",
    "123.4567890",
    "1234.567890",
    "12345.67890",
    "123456.7890",
    "1234567.890",
    "12345678.90",
    "123456789.0",
    "1234567890.",
    "12345678901",
  ].forEach(x => {
    const origin = ethers.utils.parseUnits(x);
    const packed = packPrice(origin);
    const unpacked = unpackPrice(packed);

    console.log("origin:", ethers.utils.formatUnits(origin));
    console.log("packed:", packed.toHexString());
    console.log("unpack:", ethers.utils.formatUnits(unpacked));
    console.log('-----')
  });
}

// testPackPrice()
// testPackPrice2();
