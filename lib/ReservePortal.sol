// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ReservePortal is Ownable {
  using SafeERC20 for IERC20;

  mapping(IERC20 => uint256) public withdrawableAmounts;
  mapping(uint256 => Commitment) public commitments;
  uint256 public nextCommitmentIndex;
  uint256 public voidDelay;
  address public operator;

  struct Request {
    address from;
    address to;
    uint256 value;
    uint256 gas;
    uint256 nonce;
    uint256 chainId;
    bytes data;
  }

  struct Commitment {
    // Commitment metadata
    uint256 index;
    address owner;
    IERC20 currency;
    uint256 amount;
    uint256 timestamp;
    uint256 chainId;
    // Request metadata
    Request request;
    bytes signature;
    // State metadata
    bool voided;
    bool committed;
  }

  event Escrowed(uint256 indexed index, uint256 timestamp);
  event Voided(uint256 indexed index);
  event Committed(uint256 indexed index);
  event OperatorChanged(
    address indexed previousOperator,
    address indexed nextOperator
  );
  event FundsWithdrawn(IERC20 indexed token, uint256 indexed amount);

  constructor(uint256 _initialVoidDelay, address _operator) {
    nextCommitmentIndex = 0;
    voidDelay = _initialVoidDelay;
    operator = _operator;
  }

  modifier onlyOperator() {
    require(msg.sender == operator, "Caller is not operator");
    _;
  }

  modifier pendingCommitment(uint256 _commitmentIndex) {
    Commitment storage commitment = commitments[_commitmentIndex];
    require(!commitment.voided, "Commitment is already voided");
    require(!commitment.committed, "Commitment is already committed");
    _;
  }

  // == Public write functions ==

  function batchEscrow(
    IERC20[] memory _currencies,
    uint256[] memory _amounts,
    uint256[] memory _chainIds,
    Request[] calldata _requests,
    bytes[] calldata _signatures
  ) external {
    uint256 currentTime = block.timestamp;
    for (uint256 i = 0; i < _currencies.length; i++) {
      _currencies[i].safeTransferFrom(msg.sender, address(this), _amounts[i]);
      commitments[nextCommitmentIndex] = Commitment(
        nextCommitmentIndex,
        msg.sender,
        _currencies[i],
        _amounts[i],
        currentTime,
        _chainIds[i],
        _requests[i],
        _signatures[i],
        false,
        false
      );
      emit Escrowed(nextCommitmentIndex++, currentTime);
    }
  }

  function escrow(
    IERC20 _currency,
    uint256 _amount,
    uint256 _chainId,
    Request calldata _request,
    bytes calldata _signature
  ) external {
    _currency.safeTransferFrom(msg.sender, address(this), _amount);
    uint256 currentTime = block.timestamp;
    commitments[nextCommitmentIndex] = Commitment(
      nextCommitmentIndex,
      msg.sender,
      _currency,
      _amount,
      currentTime,
      _chainId,
      _request,
      _signature,
      false,
      false
    );
    emit Escrowed(nextCommitmentIndex++, currentTime);
  }

  function void(uint256 _commitmentIndex)
    external
    pendingCommitment(_commitmentIndex)
  {
    Commitment storage commitment = commitments[_commitmentIndex];
    require(
      block.timestamp > commitment.timestamp + voidDelay,
      "User is not allowed to void commitment yet"
    );
    commitment.currency.safeTransfer(commitment.owner, commitment.amount);
    commitments[_commitmentIndex].voided = true;
    emit Voided(_commitmentIndex);
  }

  // == Operator only write functions ==

  function commit(uint256 _commitmentIndex)
    external
    onlyOperator
    pendingCommitment(_commitmentIndex)
  {
    Commitment storage commitment = commitments[_commitmentIndex];
    commitment.committed = true;
    withdrawableAmounts[commitment.currency] += commitment.amount;
    emit Committed(_commitmentIndex);
  }

  // == Owner only write functions ==

  function setOperator(address _newOperator) external onlyOwner {
    emit OperatorChanged(operator, _newOperator);
    operator = _newOperator;
  }

  function withdraw(IERC20 _token, address _to) external onlyOwner {
    uint256 amount = withdrawableAmounts[_token];
    withdraw(_token, amount, _to);
  }

  function withdraw(
    IERC20 _token,
    uint256 _amount,
    address _to
  ) public onlyOwner {
    require(
      _amount <= withdrawableAmounts[_token],
      "Cannot withdraw more than is allowed"
    );
    _token.safeTransfer(_to, _amount);
    emit FundsWithdrawn(_token, _amount);
  }
}