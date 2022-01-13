const FlutterCrowdsale = artifacts.require("FlutterCrowdsale");

module.exports = function (deployer, network, accounts) {
    const rate = "3000";
    const wallet = accounts[1];
    const token = "0x97B1aE1a480bDf9e19F377d81eF7C1E9A7eC1D61";
    deployer.deploy(FlutterCrowdsale, rate, wallet, token, {from: accounts[0]});
};
