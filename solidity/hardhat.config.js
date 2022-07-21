require("@nomicfoundation/hardhat-toolbox");

const KEY = process.env.KEY || '0x0000000000000000000000000000000000000000000000000000000000001234';

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.15",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    sbch_amber: {
      // url: 'https://moeing.tech:9545',
      url: 'http://34.92.91.11:8545',
      accounts: [ KEY ],
      gasPrice: 1050000000,
      network_id: "0x2701",
    },
    sbch_mainnet: {
      url: 'http://13.212.155.236:8545',
      accounts: [ KEY ],
      gasPrice: 1050000000,
    },
  },
};
