// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// You can also run a script with `npx hardhat run <script>`. If you do that, Hardhat
// will compile your contracts, add the Hardhat Runtime Environment's members to the
// global scope, and execute the script.
const hre = require("hardhat");

async function main() {
  // const ERC20ForTest = await ethers.getContractFactory("ERC20ForTest");
  // const wBCH = await ERC20ForTest.deploy("wBCH", ethers.utils.parseUnits('10000000', 18), 18);
  // const fUSD = await ERC20ForTest.deploy("fUSD", ethers.utils.parseUnits('10000000',  8),  8);
  // console.log('wBCH addr:', wBCH.address);
  // console.log('fUSD addr:', fUSD.address);

  const Logic = await ethers.getContractFactory("ContinueCashLogic");
  const logic = await Logic.deploy();
  console.log('logic addr:', logic.address);

  const Factory = await ethers.getContractFactory("ContinueCashFactory");
  const factory = await Factory.deploy();
  console.log('factory addr:', factory.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
