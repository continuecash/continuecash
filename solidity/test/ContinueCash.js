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
    const fUSD = await ERC20ForTest.deploy("fUSD", ethers.utils.parseUnits('10000000', 15), 15);
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
        [fUSD.address, ethers.BigNumber.from(1000), ethers.BigNumber.from(  1)],
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

  describe("ContinueCashLogic: createRobot", function () {

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

    // it("sellTo/buyFromRobot", async function () {
    //   // TODO
    // });

  });

});


function packRobotInfo(stockAmount, moneyAmount, highPrice, lowPrice) {
  return (stockAmount << 160n)
       | (moneyAmount <<  64n)
       | packPrice(highPrice, lowPrice);
}
function packPrice(high, low) {
  return high << 32n | low;
}
function encodeRobotId(addr, createdRobotCount) {
  return (BigInt(addr) << 96n) + BigInt(createdRobotCount);
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

testPackPrice()
