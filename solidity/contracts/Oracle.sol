// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOracle} from '../interfaces/IOracle.sol';
import {Subset} from './libraries/Subset.sol';

contract Oracle is IOracle {
  using Subset for mapping(uint256 => bytes32);

  /// @inheritdoc IOracle
  mapping(bytes32 _responseId => bytes32 _disputeId) public disputeOf;

  /**
   * @notice The list of all requests
   */
  mapping(bytes32 _requestId => Request) internal _requests;
  /**
   * @notice The list of all responses
   */
  mapping(bytes32 _responseId => Response) internal _responses;

  /**
   * @notice The list of all disputes
   */
  mapping(bytes32 _disputeId => Dispute) internal _disputes;

  /**
   * @notice The list of the response ids for each request
   */
  mapping(bytes32 _requestId => bytes32[] _responseId) internal _responseIds;

  /**
   * @notice The finalized response for each request
   */
  mapping(bytes32 _requestId => bytes32 _finalizedResponseId) internal _finalizedResponses;

  /**
   * @notice The id of each request in chronological order
   */
  mapping(uint256 _requestNumber => bytes32 _id) internal _requestIds;

  /**
   * @notice The nonce of the last response
   */
  uint256 internal _responseNonce;

  /// @inheritdoc IOracle
  uint256 public totalRequestCount;

  /// @inheritdoc IOracle
  function createRequest(NewRequest memory _request) external returns (bytes32 _requestId) {
    _requestId = _createRequest(_request);
  }

  /// @inheritdoc IOracle
  function createRequests(NewRequest[] calldata _requestsData) external returns (bytes32[] memory _batchRequestsIds) {
    uint256 _requestsAmount = _requestsData.length;
    _batchRequestsIds = new bytes32[](_requestsAmount);

    for (uint256 _i = 0; _i < _requestsAmount;) {
      _batchRequestsIds[_i] = _createRequest(_requestsData[_i]);
      unchecked {
        ++_i;
      }
    }
  }

  /// @inheritdoc IOracle
  function listRequests(uint256 _startFrom, uint256 _batchSize) external view returns (FullRequest[] memory _list) {
    uint256 _totalRequestsCount = totalRequestCount;

    // If trying to collect non-existent requests only, return empty array
    if (_startFrom > _totalRequestsCount) {
      return _list;
    }

    if (_batchSize > _totalRequestsCount - _startFrom) {
      _batchSize = _totalRequestsCount - _startFrom;
    }

    _list = new FullRequest[](_batchSize);

    uint256 _index;
    while (_index < _batchSize) {
      bytes32 _requestId = _requestIds[_startFrom + _index];

      _list[_index] = _getRequest(_requestId);

      unchecked {
        ++_index;
      }
    }

    return _list;
  }

  /// @inheritdoc IOracle
  function listRequestIds(uint256 _startFrom, uint256 _batchSize) external view returns (bytes32[] memory _list) {
    return _requestIds.getSubset(_startFrom, _batchSize, totalRequestCount);
  }

  /// @inheritdoc IOracle
  function getResponse(bytes32 _responseId) external view returns (Response memory _response) {
    _response = _responses[_responseId];
  }

  /// @inheritdoc IOracle
  function getRequest(bytes32 _requestId) external view returns (Request memory _request) {
    _request = _requests[_requestId];
  }

  /// @inheritdoc IOracle
  function getFullRequest(bytes32 _requestId) external view returns (FullRequest memory _request) {
    _request = _getRequest(_requestId);
  }

  /// @inheritdoc IOracle
  function getDispute(bytes32 _disputeId) external view returns (Dispute memory _dispute) {
    _dispute = _disputes[_disputeId];
  }

  /// @inheritdoc IOracle
  function proposeResponse(bytes32 _requestId, bytes calldata _responseData) external returns (bytes32 _responseId) {
    Request memory _request = _requests[_requestId];
    if (_request.createdAt == 0) revert Oracle_InvalidRequestId(_requestId);
    _responseId = _proposeResponse(msg.sender, _requestId, _request, _responseData);
  }

  /// @inheritdoc IOracle
  function proposeResponse(
    address _proposer,
    bytes32 _requestId,
    bytes calldata _responseData
  ) external returns (bytes32 _responseId) {
    Request memory _request = _requests[_requestId];
    if (msg.sender != address(_request.disputeModule)) {
      revert Oracle_NotDisputeModule(msg.sender);
    }
    _responseId = _proposeResponse(_proposer, _requestId, _request, _responseData);
  }

  /**
   * @notice Creates a new response for a given request
   * @param _proposer The address of the proposer
   * @param _requestId The id of the request
   * @param _request The request data
   * @param _responseData The response data
   * @return _responseId The id of the created response
   */
  function _proposeResponse(
    address _proposer,
    bytes32 _requestId,
    Request memory _request,
    bytes calldata _responseData
  ) internal returns (bytes32 _responseId) {
    if (_request.finalizedAt != 0) {
      revert Oracle_AlreadyFinalized(_requestId);
    }
    _responseId = keccak256(abi.encodePacked(_proposer, address(this), _requestId, _responseNonce++));
    _responses[_responseId] = _request.responseModule.propose(_requestId, _proposer, _responseData);
    _responseIds[_requestId].push(_responseId);

    emit Oracle_ResponseProposed(_requestId, _proposer, _responseId);
  }

  /// @inheritdoc IOracle
  function deleteResponse(bytes32 _responseId) external {
    Response memory _response = _responses[_responseId];
    Request memory _request = _requests[_response.requestId];

    if (disputeOf[_responseId] != bytes32(0)) {
      revert Oracle_CannotDeleteWhileDisputing(_responseId);
    }
    if (msg.sender != _response.proposer) {
      revert Oracle_CannotDeleteInvalidProposer(msg.sender, _responseId);
    }

    _request.responseModule.deleteResponse(_response.requestId, _responseId, msg.sender);

    delete _responses[_responseId];

    uint256 _length = _responseIds[_response.requestId].length;
    for (uint256 _i = 0; _i < _length;) {
      if (_responseIds[_response.requestId][_i] == _responseId) {
        _responseIds[_response.requestId][_i] = _responseIds[_response.requestId][_length - 1];
        _responseIds[_response.requestId].pop();
        break;
      }
      unchecked {
        ++_i;
      }
    }
    emit Oracle_ResponseDeleted(_response.requestId, msg.sender, _responseId);
  }

  /// @inheritdoc IOracle
  function disputeResponse(bytes32 _requestId, bytes32 _responseId) external returns (bytes32 _disputeId) {
    Request memory _request = _requests[_requestId];
    if (_request.finalizedAt != 0) {
      revert Oracle_AlreadyFinalized(_requestId);
    }
    if (disputeOf[_responseId] != bytes32(0)) {
      revert Oracle_ResponseAlreadyDisputed(_responseId);
    }

    Response storage _response = _responses[_responseId];
    if (_response.requestId != _requestId) {
      revert Oracle_InvalidResponseId(_responseId);
    }

    _disputeId = keccak256(abi.encodePacked(msg.sender, _requestId, _responseId));
    Dispute memory _dispute =
      _request.disputeModule.disputeResponse(_requestId, _responseId, msg.sender, _response.proposer);
    _disputes[_disputeId] = _dispute;
    disputeOf[_responseId] = _disputeId;

    _response.disputeId = _disputeId;

    if (_dispute.status != DisputeStatus.Active) {
      _request.disputeModule.onDisputeStatusChange(_disputeId, _dispute);
    }

    emit Oracle_ResponseDisputed(msg.sender, _responseId, _disputeId);
  }

  /// @inheritdoc IOracle
  function escalateDispute(bytes32 _disputeId) external {
    Dispute storage _dispute = _disputes[_disputeId];

    if (_dispute.createdAt == 0) revert Oracle_InvalidDisputeId(_disputeId);
    if (_dispute.status != DisputeStatus.Active) {
      revert Oracle_CannotEscalate(_disputeId);
    }

    // Change the dispute status
    _dispute.status = DisputeStatus.Escalated;

    Request memory _request = _requests[_dispute.requestId];

    // Notify the dispute module about the escalation
    _request.disputeModule.disputeEscalated(_disputeId);

    if (address(_request.resolutionModule) != address(0)) {
      // Initiate the resolution
      _request.resolutionModule.startResolution(_disputeId);
    }

    emit Oracle_DisputeEscalated(msg.sender, _disputeId);
  }

  /// @inheritdoc IOracle
  function resolveDispute(bytes32 _disputeId) external {
    Dispute memory _dispute = _disputes[_disputeId];

    if (_dispute.createdAt == 0) revert Oracle_InvalidDisputeId(_disputeId);
    // Revert if the dispute is not active nor escalated
    unchecked {
      if (uint256(_dispute.status) - 1 > 1) {
        revert Oracle_CannotResolve(_disputeId);
      }
    }

    Request memory _request = _requests[_dispute.requestId];
    if (address(_request.resolutionModule) == address(0)) {
      revert Oracle_NoResolutionModule(_disputeId);
    }

    _request.resolutionModule.resolveDispute(_disputeId);

    emit Oracle_DisputeResolved(msg.sender, _disputeId);
  }

  /// @inheritdoc IOracle
  function updateDisputeStatus(bytes32 _disputeId, DisputeStatus _status) external {
    Dispute storage _dispute = _disputes[_disputeId];
    Request memory _request = _requests[_dispute.requestId];
    if (msg.sender != address(_request.resolutionModule)) {
      revert Oracle_NotResolutionModule(msg.sender);
    }
    _dispute.status = _status;
    _request.disputeModule.onDisputeStatusChange(_disputeId, _dispute);

    emit Oracle_DisputeStatusUpdated(_disputeId, _status);
  }

  /// @inheritdoc IOracle
  function validModule(bytes32 _requestId, address _module) external view returns (bool _validModule) {
    Request memory _request = _requests[_requestId];
    _validModule = address(_request.requestModule) == _module || address(_request.responseModule) == _module
      || address(_request.disputeModule) == _module || address(_request.resolutionModule) == _module
      || address(_request.finalityModule) == _module;
  }

  /// @inheritdoc IOracle
  function getFinalizedResponseId(bytes32 _requestId) external view returns (bytes32 _finalizedResponseId) {
    _finalizedResponseId = _finalizedResponses[_requestId];
  }

  /// @inheritdoc IOracle
  function getFinalizedResponse(bytes32 _requestId) external view returns (Response memory _response) {
    _response = _responses[_finalizedResponses[_requestId]];
  }

  /// @inheritdoc IOracle
  function getResponseIds(bytes32 _requestId) external view returns (bytes32[] memory _ids) {
    _ids = _responseIds[_requestId];
  }

  /// @inheritdoc IOracle
  function finalize(bytes32 _requestId, bytes32 _finalizedResponseId) external {
    Request storage _request = _requests[_requestId];
    if (_request.finalizedAt != 0) {
      revert Oracle_AlreadyFinalized(_requestId);
    }
    Response memory _response = _responses[_finalizedResponseId];
    if (_response.requestId != _requestId) {
      revert Oracle_InvalidFinalizedResponse(_finalizedResponseId);
    }
    DisputeStatus _disputeStatus = _disputes[disputeOf[_finalizedResponseId]].status;
    if (_disputeStatus == DisputeStatus.Active || _disputeStatus == DisputeStatus.Won) {
      revert Oracle_InvalidFinalizedResponse(_finalizedResponseId);
    }

    _finalizedResponses[_requestId] = _finalizedResponseId;
    _request.finalizedAt = block.timestamp;
    _finalize(_requestId, _request);
  }

  /// @inheritdoc IOracle
  function finalize(bytes32 _requestId) external {
    Request storage _request = _requests[_requestId];
    if (_request.finalizedAt != 0) {
      revert Oracle_AlreadyFinalized(_requestId);
    }

    bytes32[] memory _requestResponseIds = _responseIds[_requestId];
    uint256 _responsesAmount = _requestResponseIds.length;

    if (_responsesAmount != 0) {
      for (uint256 _i = 0; _i < _responsesAmount;) {
        bytes32 _responseId = _requestResponseIds[_i];
        bytes32 _disputeId = disputeOf[_responseId];
        DisputeStatus _disputeStatus = _disputes[_disputeId].status;

        if (_disputeStatus != DisputeStatus.None && _disputeStatus != DisputeStatus.Lost) {
          revert Oracle_CannotFinalizeWithActiveDispute(_requestId);
        }

        unchecked {
          ++_i;
        }
      }
    }
    _request.finalizedAt = block.timestamp;
    _finalize(_requestId, _request);
  }

  /**
   * @notice Executes the finalizeRequest logic on each of the modules
   * @param _requestId The id of the request being finalized
   * @param _request The request being finalized
   */
  function _finalize(bytes32 _requestId, Request memory _request) internal {
    if (address(_request.finalityModule) != address(0)) {
      _request.finalityModule.finalizeRequest(_requestId, msg.sender);
    }
    if (address(_request.resolutionModule) != address(0)) {
      _request.resolutionModule.finalizeRequest(_requestId, msg.sender);
    }
    _request.disputeModule.finalizeRequest(_requestId, msg.sender);
    _request.responseModule.finalizeRequest(_requestId, msg.sender);
    _request.requestModule.finalizeRequest(_requestId, msg.sender);

    emit Oracle_RequestFinalized(_requestId, msg.sender);
  }

  /**
   * @notice Stores a request in the contract and configures it in the modules
   * @param _request The request to be created
   * @return _requestId The id of the created request
   */
  function _createRequest(NewRequest memory _request) internal returns (bytes32 _requestId) {
    uint256 _requestNonce = totalRequestCount++;
    _requestId = keccak256(abi.encodePacked(msg.sender, address(this), _requestNonce));
    _requestIds[_requestNonce] = _requestId;

    Request memory _storedRequest = Request({
      ipfsHash: _request.ipfsHash,
      requestModule: _request.requestModule,
      responseModule: _request.responseModule,
      disputeModule: _request.disputeModule,
      resolutionModule: _request.resolutionModule,
      finalityModule: _request.finalityModule,
      requester: msg.sender,
      nonce: _requestNonce,
      createdAt: block.timestamp,
      finalizedAt: 0
    });

    _requests[_requestId] = _storedRequest;

    _request.requestModule.setupRequest(_requestId, _request.requestModuleData);
    _request.responseModule.setupRequest(_requestId, _request.responseModuleData);
    _request.disputeModule.setupRequest(_requestId, _request.disputeModuleData);

    if (address(_request.resolutionModule) != address(0)) {
      _request.resolutionModule.setupRequest(_requestId, _request.resolutionModuleData);
    }

    if (address(_request.finalityModule) != address(0)) {
      _request.finalityModule.setupRequest(_requestId, _request.finalityModuleData);
    }

    emit Oracle_RequestCreated(_requestId, msg.sender);
  }

  /**
   * @notice Returns a FullRequest struct with all the data of a request
   * @param _requestId The id of the request
   * @return _fullRequest The full request
   */
  function _getRequest(bytes32 _requestId) internal view returns (FullRequest memory _fullRequest) {
    Request memory _storedRequest = _requests[_requestId];

    _fullRequest = FullRequest({
      requestModuleData: _storedRequest.requestModule.requestData(_requestId),
      responseModuleData: _storedRequest.responseModule.requestData(_requestId),
      disputeModuleData: _storedRequest.disputeModule.requestData(_requestId),
      resolutionModuleData: address(_storedRequest.resolutionModule) == address(0)
        ? bytes('')
        : _storedRequest.resolutionModule.requestData(_requestId),
      finalityModuleData: address(_storedRequest.finalityModule) == address(0)
        ? bytes('')
        : _storedRequest.finalityModule.requestData(_requestId),
      ipfsHash: _storedRequest.ipfsHash,
      requestModule: _storedRequest.requestModule,
      responseModule: _storedRequest.responseModule,
      disputeModule: _storedRequest.disputeModule,
      resolutionModule: _storedRequest.resolutionModule,
      finalityModule: _storedRequest.finalityModule,
      requester: _storedRequest.requester,
      nonce: _storedRequest.nonce,
      createdAt: _storedRequest.createdAt,
      finalizedAt: _storedRequest.finalizedAt,
      requestId: _requestId
    });
  }
}
