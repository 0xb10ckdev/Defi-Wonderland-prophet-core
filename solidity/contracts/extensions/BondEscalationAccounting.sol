// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {AccountingExtension} from './AccountingExtension.sol';

import {IBondEscalationAccounting} from '../../interfaces/extensions/IBondEscalationAccounting.sol';
import {IOracle} from '../../interfaces/IOracle.sol';

contract BondEscalationAccounting is AccountingExtension, IBondEscalationAccounting {
  /// @inheritdoc IBondEscalationAccounting
  mapping(bytes32 _requestId => mapping(bytes32 _disputeId => mapping(IERC20 _token => uint256 _amount))) public pledges;

  constructor(IOracle _oracle) AccountingExtension(_oracle) {}

  /// @inheritdoc IBondEscalationAccounting
  function pledge(
    address _pledger,
    bytes32 _requestId,
    bytes32 _disputeId,
    IERC20 _token,
    uint256 _amount
  ) external onlyValidModule(_requestId) {
    if (balanceOf[_pledger][_token] < _amount) revert BondEscalationAccounting_InsufficientFunds();

    pledges[_requestId][_disputeId][_token] += _amount;

    unchecked {
      balanceOf[_pledger][_token] -= _amount;
    }

    emit Pledged(_pledger, _requestId, _disputeId, _token, _amount);
  }

  /// @inheritdoc IBondEscalationAccounting
  function payWinningPledgers(
    bytes32 _requestId,
    bytes32 _disputeId,
    address[] memory _winningPledgers,
    IERC20 _token,
    uint256 _amountPerPledger
  ) external onlyValidModule(_requestId) {
    uint256 _winningPledgersLength = _winningPledgers.length;
    // TODO: check that flooring at _amountPerPledger calculation doesn't mess with this check
    if (pledges[_requestId][_disputeId][_token] < _amountPerPledger * _winningPledgersLength) {
      revert BondEscalationAccounting_InsufficientFunds();
    }

    for (uint256 i; i < _winningPledgersLength;) {
      balanceOf[_winningPledgers[i]][_token] += _amountPerPledger;

      unchecked {
        pledges[_requestId][_disputeId][_token] -= _amountPerPledger;
        ++i;
      }
    }

    emit WinningPledgersPaid(_requestId, _disputeId, _winningPledgers, _token, _amountPerPledger);
  }

  /// @inheritdoc IBondEscalationAccounting
  function releasePledge(
    bytes32 _requestId,
    bytes32 _disputeId,
    address _pledger,
    IERC20 _token,
    uint256 _amount
  ) external onlyValidModule(_requestId) {
    if (pledges[_requestId][_disputeId][_token] < _amount) revert BondEscalationAccounting_InsufficientFunds();

    balanceOf[_pledger][_token] += _amount;

    unchecked {
      pledges[_requestId][_disputeId][_token] -= _amount;
    }

    emit PledgeReleased(_requestId, _disputeId, _pledger, _token, _amount);
  }
}
