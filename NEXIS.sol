// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Nexis {
    string public name = "NEXIS";
    string public symbol = "NXS";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    uint256 public burnRateBasisPoints = 50;

    address public owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Burn(address indexed from, uint256 value);

    constructor() {
        owner = msg.sender;
        totalSupply = 444_444_444 * 10 ** uint256(decimals);
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address _to, uint256 _value) public returns (bool success) {
        _transferWithBurn(msg.sender, _to, _value);
        return true;
    }

    function approve(address _spender, uint256 _value) public returns (bool success) {
        allowance[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _value) public returns (bool success) {
        require(allowance[_from][msg.sender] >= _value, "Allowance exceeded");
        allowance[_from][msg.sender] -= _value;
        _transferWithBurn(_from, _to, _value);
        return true;
    }

    function _transferWithBurn(address _from, address _to, uint256 _value) internal {
        require(balanceOf[_from] >= _value, "Insufficient balance");
        require(_to != address(0), "Invalid address");

        uint256 burnAmount = (_value * burnRateBasisPoints) / 10000;
        uint256 sendAmount = _value - burnAmount;

        balanceOf[_from] -= _value;
        balanceOf[_to] += sendAmount;
        totalSupply -= burnAmount;

        emit Transfer(_from, _to, sendAmount);
        if (burnAmount > 0) {
            emit Burn(_from, burnAmount);
            emit Transfer(_from, address(0), burnAmount);
        }
    }
}
