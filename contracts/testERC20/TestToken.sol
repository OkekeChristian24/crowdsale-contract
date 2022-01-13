pragma solidity ^0.5.0;

import "../helpers/ERC20.sol";
import "../helpers/ERC20Detailed.sol";

contract TestToken is ERC20, ERC20Detailed{
    constructor() ERC20Detailed("TestToken", "TTKN", 18) public{
        _mint(msg.sender, 100000000000000000000000000);
    }
}