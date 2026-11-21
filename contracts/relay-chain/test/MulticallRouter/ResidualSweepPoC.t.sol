// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MyToken} from "../../contracts/test-utils/MyToken.sol";
import {Call} from "../../contracts/routers/IMulticallRouter.sol";
import {MulticallRouter} from "../../contracts/routers/MulticallRouter.sol";

/// @notice Demonstrates cross-bundle contamination when a routed bundle omits
/// its residual sweep. This is a local unit-test harness, not a live-chain exploit.
contract ResidualSweepPoCTest is Test {
  MulticallRouter internal router;
  MyToken internal token;
  address internal depository;
  address internal recipientA;
  address internal recipientB;

  function setUp() public {
    address admin = makeAddr("admin");
    depository = makeAddr("depository");
    recipientA = makeAddr("recipientA");
    recipientB = makeAddr("recipientB");

    router = new MulticallRouter(admin);
    token = new MyToken();

    bytes32 depositoryRole = router.DEPOSITORY_ROLE();
    vm.prank(admin);
    router.grantRole(depositoryRole, depository);
  }

  function _single(address to, bytes memory data)
    internal
    pure
    returns (Call[] memory calls)
  {
    calls = new Call[](1);
    calls[0] = Call({
      to: to,
      data: data,
      value: 0,
      allowFailure: false
    });
  }

  function _sweep(address recipient)
    internal
    view
    returns (Call[] memory)
  {
    return _single(
      address(router),
      abi.encodeCall(
        MulticallRouter.sweep,
        (_currencies(address(token)), recipient)
      )
    );
  }

  function _currencies(address currency)
    internal
    pure
    returns (address[] memory currencies)
  {
    currencies = new address[](1);
    currencies[0] = currency;
  }

  function testBundleWithoutSweepLeavesResidualOnRouter() public {
    token.mintFor(100, address(router));

    // Bundle A pays 40 to its intended recipient but omits the final sweep.
    Call[] memory calls = _single(
      address(token),
      abi.encodeCall(IERC20.transfer, (recipientA, 40))
    );

    vm.prank(depository);
    router.multicall(calls);

    assertEq(token.balanceOf(recipientA), 40);
    assertEq(token.balanceOf(address(router)), 60);
  }

  function testNextBundleCanSweepPreviousBundlesResidual() public {
    // Simulate withdrawal A: 100 tokens arrive, 40 are paid, 60 are stranded.
    token.mintFor(100, address(router));
    Call[] memory bundleA = _single(
      address(token),
      abi.encodeCall(IERC20.transfer, (recipientA, 40))
    );

    vm.prank(depository);
    router.multicall(bundleA);

    assertEq(token.balanceOf(address(router)), 60);

    // Simulate withdrawal B: its own 10 tokens arrive. Its valid sweep sends
    // the router's entire balance to B's recipient, including A's 60 tokens.
    token.mintFor(10, address(router));

    vm.prank(depository);
    router.multicall(_sweep(recipientB));

    assertEq(token.balanceOf(recipientB), 70);
    assertEq(token.balanceOf(address(router)), 0);
    assertEq(token.balanceOf(recipientA), 40);
  }
}
