// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ZkHarvestToken is ERC20("Zk-Harvest", "ZKH"), Ownable {
  uint256 private constant preMinedSupply = 66000000 * 1e18;
  uint256 public constant maxSupply = 100000000 * 1e18; // Total Supply. Maximum token that can be minted.
  uint256 public totalMinted = 0; // Keep track of all minted token, independently of burnt tokens

  event Burn(address indexed from, uint256 value);

  constructor() {
    mint(msg.sender, preMinedSupply);
  }

  function mint(address _to, uint256 _amount) public onlyOwner {
    require(_amount + totalMinted <= maxSupply, "ZKH: maxSupply hit");
    totalMinted = totalMinted + _amount;
    _mint(_to, _amount);
  }

  function burn(uint256 _amount) public {
    _burn(msg.sender, _amount);
    emit Burn(msg.sender, _amount);
  }
}
