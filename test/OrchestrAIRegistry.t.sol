// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {OrchestrAIRegistry} from "../src/OrchestrAIRegistry.sol";

contract OrchestrAIRegistryTest is Test {
    OrchestrAIRegistry public registry;

    function setUp() public {
        registry = new OrchestrAIRegistry();
    }

    function test_deployment() public view {
        assertEq(registry.owner(), address(this));
    }
}
