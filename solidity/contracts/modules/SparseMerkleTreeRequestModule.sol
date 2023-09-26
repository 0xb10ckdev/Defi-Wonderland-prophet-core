// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISparseMerkleTreeRequestModule} from '../../interfaces/modules/ISparseMerkleTreeRequestModule.sol';
import {IOracle} from '../../interfaces/IOracle.sol';
import {Module} from '../Module.sol';

contract SparseMerkleTreeRequestModule is Module, ISparseMerkleTreeRequestModule {
  constructor(IOracle _oracle) Module(_oracle) {}

  function moduleName() public pure returns (string memory _moduleName) {
    _moduleName = 'SparseMerkleTreeRequestModule';
  }

  /// @inheritdoc ISparseMerkleTreeRequestModule
  function decodeRequestData(bytes32 _requestId) public view returns (RequestParameters memory _params) {
    _params = abi.decode(requestData[_requestId], (RequestParameters));
  }

  /**
   * @notice Hook triggered after setting up a request. Bonds the requester's payment amount
   * @param _requestId The ID of the request being setup
   */
  function _afterSetupRequest(bytes32 _requestId, bytes calldata) internal override {
    RequestParameters memory _params = decodeRequestData(_requestId);
    IOracle.Request memory _request = ORACLE.getRequest(_requestId);
    _params.accountingExtension.bond(_request.requester, _requestId, _params.paymentToken, _params.paymentAmount);
  }

  /// @inheritdoc ISparseMerkleTreeRequestModule
  function finalizeRequest(
    bytes32 _requestId,
    address _finalizer
  ) external override(ISparseMerkleTreeRequestModule, Module) onlyOracle {
    IOracle.Request memory _request = ORACLE.getRequest(_requestId);
    IOracle.Response memory _response = ORACLE.getFinalizedResponse(_requestId);
    RequestParameters memory _params = decodeRequestData(_requestId);
    if (_response.createdAt != 0) {
      _params.accountingExtension.pay(
        _requestId, _request.requester, _response.proposer, _params.paymentToken, _params.paymentAmount
      );
    } else {
      _params.accountingExtension.release(_request.requester, _requestId, _params.paymentToken, _params.paymentAmount);
    }
    emit RequestFinalized(_requestId, _finalizer);
  }
}
