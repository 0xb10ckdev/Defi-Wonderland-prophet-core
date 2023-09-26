// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IBondedDisputeModule} from '../../interfaces/modules/IBondedDisputeModule.sol';
import {IOracle} from '../../interfaces/IOracle.sol';
import {Module} from '../Module.sol';

contract BondedDisputeModule is Module, IBondedDisputeModule {
  constructor(IOracle _oracle) Module(_oracle) {}

  function moduleName() external pure returns (string memory _moduleName) {
    return 'BondedDisputeModule';
  }

  /// @inheritdoc IBondedDisputeModule
  function decodeRequestData(bytes32 _requestId) public view returns (RequestParameters memory _params) {
    _params = abi.decode(requestData[_requestId], (RequestParameters));
  }

  /// @inheritdoc IBondedDisputeModule
  function disputeEscalated(bytes32 _disputeId) external onlyOracle {}

  /// @inheritdoc IBondedDisputeModule
  function disputeResponse(
    bytes32 _requestId,
    bytes32 _responseId,
    address _disputer,
    address _proposer
  ) external onlyOracle returns (IOracle.Dispute memory _dispute) {
    _dispute = IOracle.Dispute({
      disputer: _disputer,
      responseId: _responseId,
      proposer: _proposer,
      requestId: _requestId,
      status: IOracle.DisputeStatus.Active,
      createdAt: block.timestamp
    });

    RequestParameters memory _params = decodeRequestData(_requestId);
    _params.accountingExtension.bond(_disputer, _requestId, _params.bondToken, _params.bondSize);

    emit ResponseDisputed(_requestId, _responseId, _disputer, _proposer);
  }

  /// @inheritdoc IBondedDisputeModule
  function onDisputeStatusChange(bytes32, /* _disputeId */ IOracle.Dispute memory _dispute) external onlyOracle {
    RequestParameters memory _params = decodeRequestData(_dispute.requestId);
    IOracle.DisputeStatus _status = _dispute.status;
    address _proposer = _dispute.proposer;
    address _disputer = _dispute.disputer;

    if (_status == IOracle.DisputeStatus.NoResolution) {
      // No resolution, we release both bonds
      _params.accountingExtension.release(_disputer, _dispute.requestId, _params.bondToken, _params.bondSize);
      _params.accountingExtension.release(_proposer, _dispute.requestId, _params.bondToken, _params.bondSize);
    } else if (_status == IOracle.DisputeStatus.Won) {
      // Disputer won, we pay the disputer and release their bond
      _params.accountingExtension.pay(_dispute.requestId, _proposer, _disputer, _params.bondToken, _params.bondSize);
      _params.accountingExtension.release(_disputer, _dispute.requestId, _params.bondToken, _params.bondSize);
    } else if (_status == IOracle.DisputeStatus.Lost) {
      // Disputer lost, we pay the proposer and release their bond
      _params.accountingExtension.pay(_dispute.requestId, _disputer, _proposer, _params.bondToken, _params.bondSize);
      _params.accountingExtension.release(_proposer, _dispute.requestId, _params.bondToken, _params.bondSize);
    }

    emit DisputeStatusChanged(_dispute.requestId, _dispute.responseId, _disputer, _proposer, _status);
  }
}
