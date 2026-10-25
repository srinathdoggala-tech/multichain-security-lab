// SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

contract StakingPool {
    uint256 public totalStaked;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public rewardsOf;
    mapping(address => uint256) public userRewardPerTokenPaid;

    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken();
        if (_account != address(0)) {
            rewardsOf[_account] = earned(_account);
            userRewardPerTokenPaid[_account] = rewardPerTokenStored;
        }
        _;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored;
    }

    function earned(address _account) public view returns (uint256) {
        return
            ((balanceOf[_account] * (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e18) + rewardsOf[_account];
    }

    function stake() public payable updateReward(msg.sender) {
        require(msg.value > 0, "Zero stake");
        balanceOf[msg.sender] += msg.value;
        totalStaked += msg.value;
    }

    function withdraw(uint256 _amount) public updateReward(msg.sender) {
        require(balanceOf[msg.sender] >= _amount, "Low balance");
        balanceOf[msg.sender] -= _amount;
        totalStaked -= _amount;
        payable(msg.sender).transfer(_amount);
    }

    function getReward() public updateReward(msg.sender) {
        uint256 reward = rewardsOf[msg.sender];
        if (reward > 0) {
            rewardsOf[msg.sender] = 0;
            payable(msg.sender).transfer(reward);
        }
    }

    function notifyRewardAmount() public payable updateReward(address(0)) {
        require(msg.value > 0, "Zero reward");
        if (totalStaked > 0) {
            rewardPerTokenStored += (msg.value * 1e18) / totalStaked;
        }
    }
    receive() external payable {}
}
