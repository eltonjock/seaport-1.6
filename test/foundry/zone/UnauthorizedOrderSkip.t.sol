// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ConsiderationItemLib,
    FulfillmentComponentLib,
    FulfillmentLib,
    OfferItemLib,
    OrderComponentsLib,
    OrderLib,
    OrderParametersLib,
    SeaportArrays
} from "seaport-sol/src/lib/SeaportStructLib.sol";

import { UnavailableReason } from "seaport-sol/src/SpaceEnums.sol";

import { BaseOrderTest } from "../utils/BaseOrderTest.sol";

import { VerboseAuthZone } from
    "./impl/VerboseAuthZone.sol";

import {
    AdvancedOrder,
    BasicOrderParameters,
    ConsiderationItem,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent,
    ItemType,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {
    BasicOrderType,
    OrderType,
    Side
} from "seaport-types/src/lib/ConsiderationEnums.sol";

import { ConsiderationInterface } from
    "seaport-types/src/interfaces/ConsiderationInterface.sol";

import { FulfillAvailableHelper } from
    "seaport-sol/src/fulfillments/available/FulfillAvailableHelper.sol";

import { MatchFulfillmentHelper } from
    "seaport-sol/src/fulfillments/match/MatchFulfillmentHelper.sol";

import "forge-std/console.sol";
import { helm } from "seaport-sol/src/helm.sol";

contract UnauthorizedOrderSkipTest is BaseOrderTest {
    using FulfillmentLib for Fulfillment;
    using FulfillmentComponentLib for FulfillmentComponent;
    using FulfillmentComponentLib for FulfillmentComponent[];
    using OfferItemLib for OfferItem;
    using OfferItemLib for OfferItem[];
    using ConsiderationItemLib for ConsiderationItem;
    using ConsiderationItemLib for ConsiderationItem[];
    using OrderComponentsLib for OrderComponents;
    using OrderParametersLib for OrderParameters;
    using OrderLib for Order;
    using OrderLib for Order[];

    MatchFulfillmentHelper matchFulfillmentHelper;
    FulfillAvailableHelper fulfillAvailableFulfillmentHelper;

    struct Context {
        ConsiderationInterface seaport;
        FulfillFuzzInputs fulfillArgs;
        MatchFuzzInputs matchArgs;
    }

    struct FulfillFuzzInputs {
        uint256 tokenId;
        uint128 amount;
        uint128 excessNativeTokens;
        uint256 orderCount;
        uint256 considerationItemsPerOrderCount;
        uint256 maximumFulfilledCount;
        address offerRecipient;
        address considerationRecipient;
        bytes32 zoneHash;
        uint256 salt;
        bool shouldReturnInvalidMagicValue;
        bool shouldRevert;
        bool shouldAggregateFulfillmentComponents;
        bool shouldUseConduit;
        bool shouldIncludeNativeConsideration;
        bool shouldIncludeExcessOfferItems;
        bool shouldSpecifyRecipient;
        bool shouldIncludeJunkDataInAdvancedOrder;
    }

    struct MatchFuzzInputs {
        uint256 tokenId;
        uint128 amount;
        uint128 excessNativeTokens;
        uint256 orderPairCount;
        uint256 considerationItemsPerPrimeOrderCount;
        // This is currently used only as the unspent prime offer item recipient
        // but would also set the recipient for unspent mirror offer items if
        // any were added in the test in the future.
        address unspentPrimeOfferItemRecipient;
        string primeOfferer;
        string mirrorOfferer;
        bytes32 zoneHash;
        uint256 salt;
        bool shouldReturnInvalidMagicValue;
        bool shouldRevert;
        bool shouldUseConduit;
        bool shouldIncludeNativeConsideration;
        bool shouldIncludeExcessOfferItems;
        bool shouldSpecifyUnspentOfferItemRecipient;
        bool shouldIncludeJunkDataInAdvancedOrder;
    }

    // Used for stack depth management.
    struct MatchAdvancedOrdersInfra {
        Order[] orders;
        Fulfillment[] fulfillments;
        AdvancedOrder[] advancedOrders;
        CriteriaResolver[] criteriaResolvers;
        uint256 callerBalanceBefore;
        uint256 callerBalanceAfter;
        uint256 primeOffererBalanceBefore;
        uint256 primeOffererBalanceAfter;
    }

    // Used for stack depth management.
    struct FulfillAvailableAdvancedOrdersInfra {
        AdvancedOrder[] advancedOrders;
        FulfillmentComponent[][] offerFulfillmentComponents;
        FulfillmentComponent[][] considerationFulfillmentComponents;
        CriteriaResolver[] criteriaResolvers;
        uint256 callerBalanceBefore;
        uint256 callerBalanceAfter;
        uint256 considerationRecipientNativeBalanceBefore;
        uint256 considerationRecipientToken1BalanceBefore;
        uint256 considerationRecipientToken2BalanceBefore;
        uint256 considerationRecipientNativeBalanceAfter;
        uint256 considerationRecipientToken1BalanceAfter;
        uint256 considerationRecipientToken2BalanceAfter;
    }

    // Used for stack depth management.
    struct OrderAndFulfillmentInfra {
        OfferItem[] offerItemArray;
        ConsiderationItem[] considerationItemArray;
        OrderComponents orderComponents;
        Order[] orders;
        Fulfillment fulfillment;
        Fulfillment[] fulfillments;
    }

    // Used for stack depth management.
    struct OrderComponentInfra {
        OrderComponents orderComponents;
        OrderComponents[] orderComponentsArray;
        OfferItem[][] offerItemArray;
        ConsiderationItem[][] considerationItemArray;
        ConsiderationItem nativeConsiderationItem;
        ConsiderationItem erc20ConsiderationItemOne;
        ConsiderationItem erc20ConsiderationItemTwo;
    }

    event Authorized(bytes32 orderHash);
    event AuthorizeOrderReverted(bytes32 orderHash);
    event AuthorizeOrderMuggleValue(bytes32 orderHash);

    error OrderNotAuthorized();

    FulfillFuzzInputs emptyFulfill;
    MatchFuzzInputs emptyMatch;

    Account fuzzPrimeOfferer;
    Account fuzzMirrorOfferer;

    string constant SINGLE_721 = "single 721";
    string constant STD_RESTRICTED = "validation zone";

    function test(function(Context memory) external fn, Context memory context)
        internal
    {
        try fn(context) {
            fail();
        } catch (bytes memory reason) {
            assertPass(reason);
        }
    }

    function setUp() public override {
        super.setUp();
        matchFulfillmentHelper = new MatchFulfillmentHelper();
        fulfillAvailableFulfillmentHelper = new FulfillAvailableHelper();
        conduitController.updateChannel(address(conduit), address(this), true);
        referenceConduitController.updateChannel(
            address(referenceConduit), address(this), true
        );

        // create a default consideration for a single 721;
        // note that it does not have recipient, token or
        // identifier set
        ConsiderationItemLib.empty().withItemType(ItemType.ERC721)
            .withStartAmount(1).withEndAmount(1).saveDefault(SINGLE_721);

        // create a default offerItem for a single 721;
        // note that it does not have token or identifier set
        OfferItemLib.empty().withItemType(ItemType.ERC721).withStartAmount(1)
            .withEndAmount(1).saveDefault(SINGLE_721);

        OrderComponentsLib.empty().withOfferer(offerer1.addr)
        .withOrderType(OrderType.FULL_RESTRICTED).withStartTime(
            block.timestamp
        ).withEndTime(block.timestamp + 1).withZoneHash(bytes32(0)).withSalt(0)
            .withConduitKey(conduitKeyOne)
            .saveDefault(STD_RESTRICTED);
    }

    function testMatch_x(MatchFuzzInputs memory _matchArgs) public {
        _matchArgs = _boundMatchArgs(_matchArgs);

        // test(
        //     this.execMatch,
        //     Context({
        //         seaport: consideration,
        //         matchArgs: _matchArgs,
        //         fulfillArgs: emptyFulfill
        //     })
        // );
        test(
            this.execMatch,
            Context({
                seaport: referenceConsideration,
                matchArgs: _matchArgs,
                fulfillArgs: emptyFulfill
            })
        );
    }

    // TODO: Strip out the stuff that's extraneous or redundant.
    function execMatch(Context memory context) public stateless {
        console.log("context.matchArgs.shouldRevert");
        console.log(context.matchArgs.shouldRevert);

        console.log("context.matchArgs.shouldReturnInvalidMagicValue");
        console.log(context.matchArgs.shouldReturnInvalidMagicValue);

        // Set up the zone.
        VerboseAuthZone verboseZone =
            new VerboseAuthZone(context.matchArgs.shouldReturnInvalidMagicValue, context.matchArgs.shouldRevert);

        vm.label(address(verboseZone), "VerboseZone");

         // Set up the infrastructure for this function in a struct to avoid
        // stack depth issues.
        MatchAdvancedOrdersInfra memory infra = MatchAdvancedOrdersInfra({
            orders: new Order[](context.matchArgs.orderPairCount),
            fulfillments: new Fulfillment[](context.matchArgs.orderPairCount),
            advancedOrders: new AdvancedOrder[](context.matchArgs.orderPairCount),
            criteriaResolvers: new CriteriaResolver[](0),
            callerBalanceBefore: 0,
            callerBalanceAfter: 0,
            primeOffererBalanceBefore: 0,
            primeOffererBalanceAfter: 0
        });

        // The prime offerer is offering NFTs and considering ERC20/Native.
        fuzzPrimeOfferer =
            makeAndAllocateAccount(context.matchArgs.primeOfferer);
        // The mirror offerer is offering ERC20/Native and considering NFTs.
        fuzzMirrorOfferer =
            makeAndAllocateAccount(context.matchArgs.mirrorOfferer);

        // Create the orders and fulfuillments.
        (infra.orders, infra.fulfillments) =
            _buildOrdersAndFulfillmentsMirrorOrdersFromFuzzArgs(
                context,
                address(verboseZone)
            );

        // Set up the advanced orders array.
        infra.advancedOrders = new AdvancedOrder[](infra.orders.length);

        // Convert the orders to advanced orders.
        for (uint256 i = 0; i < infra.orders.length; i++) {
            infra.advancedOrders[i] = infra.orders[i].toAdvancedOrder(
                1,
                1,
                context.matchArgs.shouldIncludeJunkDataInAdvancedOrder
                    ? bytes(abi.encodePacked(context.matchArgs.salt))
                    : bytes("")
            );
        }

        // Store the native token balances before the call for later reference.
        infra.callerBalanceBefore = address(this).balance;
        infra.primeOffererBalanceBefore = address(fuzzPrimeOfferer.addr).balance;

        // Set up expectations for the call.
        uint256 offererCounter =
        context.seaport.getCounter(infra.orders[0].parameters.offerer);

        // Set up the first orderHash.
        bytes32 orderHash = context.seaport.getOrderHash(
            infra.orders[0].parameters.toOrderComponents(offererCounter));

        console.log("context.matchArgs.shouldRevert");
        console.log(context.matchArgs.shouldRevert);

        if (context.matchArgs.shouldReturnInvalidMagicValue) {
            // Expect AuthorizeOrderMuggleValue event.
            vm.expectEmit(true, false, false, true, address(verboseZone));
            emit AuthorizeOrderMuggleValue(orderHash);
            vm.expectRevert(
                abi.encodeWithSignature("InvalidRestrictedOrder(bytes32)", orderHash)
            );
        } else if (context.matchArgs.shouldRevert) {
            // Expect AuthorizeOrderReverted event.
            vm.expectEmit(true, false, false, true, address(verboseZone));
            emit AuthorizeOrderReverted(orderHash);
            vm.expectRevert(
                abi.encodeWithSignature(
                    "InvalidRestrictedOrder(bytes32)",
                    orderHash
                )
            );
        } else {
            if (!context.matchArgs.shouldRevert && !context.matchArgs.shouldReturnInvalidMagicValue) {

                bytes32[] memory orderHashesToAuth = new bytes32[](infra.orders.length);

                // Iterate over the orders and authorize them, then set up event expectations.
                for (uint256 i = 0; i < infra.orders.length; i++) {
                    offererCounter =
                        context.seaport.getCounter(infra.orders[i].parameters.offerer);

                    // Set up the orderHash.
                    orderHash = context.seaport.getOrderHash(
                        infra.orders[i].parameters.toOrderComponents(offererCounter)
                    );

                    orderHashesToAuth[i] = orderHash;

                    // Call `setAuthorizationStatus` on the verboseZone.
                    verboseZone.setAuthorizationStatus(orderHash, true);
                }

                // Iterate again and set up the expectations for the events.
                // (Can't call `getOrderHash` between `vm.expectEmit` calls).
                for (uint256 i = 0; i < orderHashesToAuth.length; i++) {
                    if (orderHashesToAuth[i] != bytes32(0)) {
                        // Expect Authorized event.
                        vm.expectEmit(true, false, false, true, address(verboseZone));
                        emit Authorized(orderHashesToAuth[i]);
                    }
                }
            }

            if (
                fuzzPrimeOfferer
                    // If the fuzzPrimeOfferer and fuzzMirrorOfferer are the same
                    // address, then the ERC20 transfers will be filtered.
                    .addr != fuzzMirrorOfferer.addr
            ) {
                if (
                    // When shouldIncludeNativeConsideration is false, there will be
                    // exactly one token1 consideration item per orderPairCount. And
                    // they'll all get aggregated into a single transfer.
                    !context.matchArgs.shouldIncludeNativeConsideration
                ) {
                    // This checks that the ERC20 transfers were all aggregated into
                    // a single transfer.
                    vm.expectEmit(true, true, false, true, address(token1));
                    emit Transfer(
                        address(fuzzMirrorOfferer.addr), // from
                        address(fuzzPrimeOfferer.addr), // to
                        context.matchArgs.amount * context.matchArgs.orderPairCount
                    );
                }

                if (
                    context
                        .matchArgs
                        // When considerationItemsPerPrimeOrderCount is 3, there will be
                        // exactly one token2 consideration item per orderPairCount.
                        // And they'll all get aggregated into a single transfer.
                        .considerationItemsPerPrimeOrderCount >= 3
                ) {
                    vm.expectEmit(true, true, false, true, address(token2));
                    emit Transfer(
                        address(fuzzMirrorOfferer.addr), // from
                        address(fuzzPrimeOfferer.addr), // to
                        context.matchArgs.amount * context.matchArgs.orderPairCount
                    );
                }
            }
        }

        // Make the call to Seaport.
        context.seaport.matchAdvancedOrders{
            value: (context.matchArgs.amount * context.matchArgs.orderPairCount)
                + context.matchArgs.excessNativeTokens
        }(
            infra.advancedOrders,
            infra.criteriaResolvers,
            infra.fulfillments,
            // If shouldSpecifyUnspentOfferItemRecipient is true, send the
            // unspent offer items to the recipient specified by the fuzz args.
            // Otherwise, pass in the zero address, which will result in the
            // unspent offer items being sent to the caller.
            context.matchArgs.shouldSpecifyUnspentOfferItemRecipient
                ? address(context.matchArgs.unspentPrimeOfferItemRecipient)
                : address(0)
        );

        // If the call should return an invalid magic value or revert, return
        // early.
        if (context.matchArgs.shouldReturnInvalidMagicValue
                || context.matchArgs.shouldRevert
        ) {
            return;
        }

        // Note the native token balances after the call for later checks.
        infra.callerBalanceAfter = address(this).balance;
        infra.primeOffererBalanceAfter = address(fuzzPrimeOfferer.addr).balance;

        // Check that the NFTs were transferred to the expected recipient.
        for (uint256 i = 0; i < context.matchArgs.orderPairCount; i++) {
            assertEq(
                test721_1.ownerOf(context.matchArgs.tokenId + i),
                fuzzMirrorOfferer.addr
            );
        }

        if (context.matchArgs.shouldIncludeExcessOfferItems) {
            // Check that the excess offer NFTs were transferred to the expected
            // recipient.
            for (uint256 i = 0; i < context.matchArgs.orderPairCount; i++) {
                assertEq(
                    test721_1.ownerOf((context.matchArgs.tokenId + i) * 2),
                    context.matchArgs.shouldSpecifyUnspentOfferItemRecipient
                        ? context.matchArgs.unspentPrimeOfferItemRecipient
                        : address(this)
                );
            }
        }

        if (context.matchArgs.shouldIncludeNativeConsideration) {
            // Check that ETH is moving from the caller to the prime offerer.
            // This also checks that excess native tokens are being swept back
            // to the caller.
            assertEq(
                infra.callerBalanceBefore
                    - context.matchArgs.amount * context.matchArgs.orderPairCount,
                infra.callerBalanceAfter
            );
            assertEq(
                infra.primeOffererBalanceBefore
                    + context.matchArgs.amount * context.matchArgs.orderPairCount,
                infra.primeOffererBalanceAfter
            );
        } else {
            assertEq(infra.callerBalanceBefore, infra.callerBalanceAfter);
        }
    }

    function testFulfillAvailable_x(
        FulfillFuzzInputs memory fulfillArgs
    ) public {
        fulfillArgs = _boundFulfillArgs(fulfillArgs);

        test(
            this.execFulfillAvailable,
            Context(consideration, fulfillArgs, emptyMatch)
        );
        // test(
        //     this.execFulfillAvailable,
        //     Context(referenceConsideration, fulfillArgs, emptyMatch)
        // );
    }

    function execFulfillAvailable(Context memory context)
        external
        stateless
    {
        // Set up the infrastructure.
        FulfillAvailableAdvancedOrdersInfra memory infra =
        FulfillAvailableAdvancedOrdersInfra({
            advancedOrders: new AdvancedOrder[]( context.fulfillArgs.orderCount),
            offerFulfillmentComponents: new FulfillmentComponent[][](context.fulfillArgs.orderCount),
            considerationFulfillmentComponents: new FulfillmentComponent[][](context.fulfillArgs.orderCount),
            criteriaResolvers: new CriteriaResolver[](0),
            callerBalanceBefore: address(this).balance,
            callerBalanceAfter: address(this).balance,
            considerationRecipientNativeBalanceBefore: context
                .fulfillArgs
                .considerationRecipient
                .balance,
            considerationRecipientToken1BalanceBefore: token1.balanceOf(
                context.fulfillArgs.considerationRecipient
                ),
            considerationRecipientToken2BalanceBefore: token2.balanceOf(
                context.fulfillArgs.considerationRecipient
                ),
            considerationRecipientNativeBalanceAfter: context
                .fulfillArgs
                .considerationRecipient
                .balance,
            considerationRecipientToken1BalanceAfter: token1.balanceOf(
                context.fulfillArgs.considerationRecipient
                ),
            considerationRecipientToken2BalanceAfter: token2.balanceOf(
                context.fulfillArgs.considerationRecipient
                )
        });

        // Use a conduit sometimes.
        bytes32 conduitKey =
            context.fulfillArgs.shouldUseConduit ? conduitKeyOne : bytes32(0);

        // Mint enough ERC721s to cover the number of NFTs for sale.
        for (uint256 i; i < context.fulfillArgs.orderCount; i++) {
            test721_1.mint(offerer1.addr, context.fulfillArgs.tokenId + i);
        }

        // Mint enough ERC20s to cover price per NFT * NFTs for sale.
        token1.mint(
            address(this),
            context.fulfillArgs.amount * context.fulfillArgs.orderCount
        );
        token2.mint(
            address(this),
            context.fulfillArgs.amount * context.fulfillArgs.orderCount
        );

        // Set up the zone.
        VerboseAuthZone verboseZone =
            new VerboseAuthZone(context.fulfillArgs.shouldReturnInvalidMagicValue, context.fulfillArgs.shouldRevert);

        vm.label(address(verboseZone), "VerboseZone");

        // Create the orders.
        infra.advancedOrders = _buildOrdersFromFuzzArgs(context, offerer1.key, address(verboseZone));

        // Create the fulfillments.
        if (context.fulfillArgs.shouldAggregateFulfillmentComponents) {
            (
                infra.offerFulfillmentComponents,
                infra.considerationFulfillmentComponents
            ) = fulfillAvailableFulfillmentHelper
                .getAggregatedFulfillmentComponents(infra.advancedOrders);
        } else {
            (
                infra.offerFulfillmentComponents,
                infra.considerationFulfillmentComponents
            ) = fulfillAvailableFulfillmentHelper.getNaiveFulfillmentComponents(
                infra.advancedOrders
            );
        }

        // // Store balances before the call for later comparison.
        // infra.callerBalanceBefore = address(this).balance;
        // infra.considerationRecipientNativeBalanceBefore =
        //     address(context.fulfillArgs.considerationRecipient).balance;
        // infra.considerationRecipientToken1BalanceBefore =
        //     token1.balanceOf(context.fulfillArgs.considerationRecipient);
        // infra.considerationRecipientToken2BalanceBefore =
        //     token2.balanceOf(context.fulfillArgs.considerationRecipient);

        // Set up expectations for the call.
        if (context.fulfillArgs.shouldReturnInvalidMagicValue) {
            return;

            ////////////////////////////////////////////////////////////////////
            //                                                                //
            // I'm ignoring the invalid magic value path for now, while       //
            // figuring out the revert branch.                                //
            //                                                                //
            ////////////////////////////////////////////////////////////////////

            // bytes32[] memory orderHashesThatShouldReturnInvalidMagicValueInAuth = new bytes32[](infra.advancedOrders.length);

            // // Iterate over the orders.
            // for (uint256 i = 0; i < infra.advancedOrders.length; i++) {
            //     uint256 offererCounter = context.seaport.getCounter(
            //         infra.advancedOrders[i].parameters.offerer
            //     );

            //     // Set up the orderHash.
            //     bytes32 orderHash = context.seaport.getOrderHash(
            //         infra.advancedOrders[i].parameters.toOrderComponents(
            //             offererCounter
            //         )
            //     );

            //     if ((uint256(orderHash) % 2) == 0) {
            //         orderHashesThatShouldReturnInvalidMagicValueInAuth[i] = orderHash;
            //     } else {
            //         // Auth the order.
            //         verboseZone.setAuthorizationStatus(orderHash, true);
            //     }
            // }

            // // Iterate again to set the expectations for the events.
            // for (uint256 i = 0; i < context.fulfillArgs.maximumFulfilledCount; i++) {
            //     if (orderHashesThatShouldReturnInvalidMagicValueInAuth[i] != bytes32(0)) {
            //         console.log("Expecting a skip on orderHash, invalid");
            //         console.logBytes32(orderHashesThatShouldReturnInvalidMagicValueInAuth[i]);

            //         // Expect AuthorizeOrderMuggleValue event.
            //         vm.expectEmit(true, false, false, true, address(verboseZone));
            //         emit AuthorizeOrderMuggleValue(orderHashesThatShouldReturnInvalidMagicValueInAuth[i]);

            //         // TODO: REMOVE, EXPERIMENT.
            //         if (i == 0) {
            //             vm.expectRevert();
            //             //     abi.encodeWithSignature("InvalidRestrictedOrder(bytes32)", bytes32(0))
            //             // );

            //             break;
            //         }
            //     }
            // }
        } else if (context.fulfillArgs.shouldRevert) {
            bytes32[] memory orderHashesThatShouldRevertInAuth = new bytes32[](infra.advancedOrders.length);

            // Iterate over the orders and expect AuthorizeOrderReverted events.
            for (uint256 i = 0; i < infra.advancedOrders.length; i++) {

                uint256 offererCounter;
                bytes32 orderHash;

                offererCounter = context.seaport.getCounter(
                    infra.advancedOrders[i].parameters.offerer
                );

                // Set up the orderHash.
                orderHash = context.seaport.getOrderHash(
                    infra.advancedOrders[i].parameters.toOrderComponents(
                        offererCounter
                    )
                );

                if ((uint256(orderHash) % 2) == 0) {
                    orderHashesThatShouldRevertInAuth[i] = orderHash;
                } else {
                    // Auth the order.
                    verboseZone.setAuthorizationStatus(orderHash, true);
                }
            }

            for (uint256 i = 0; i < context.fulfillArgs.maximumFulfilledCount; i++) {
                if (orderHashesThatShouldRevertInAuth[i] != bytes32(0)) {
                    console.log("Expecting a skip on orderHash, revert");
                    console.logBytes32(orderHashesThatShouldRevertInAuth[i]);

                    // Expect AuthorizeOrderReverted event.
                    vm.expectEmit(true, false, false, true, address(verboseZone));
                    emit AuthorizeOrderReverted(orderHashesThatShouldRevertInAuth[i]);
                }
            }
        } else {

            ////////////////////////////////////////////////////////////////////
            //                                                                //
            // I'm ignoring the no-skip-or-revert path for now, while figuring//
            // out the revert branch.                                         //
            //                                                                //
            ////////////////////////////////////////////////////////////////////

            // if (!context.fulfillArgs.shouldRevert && !context.fulfillArgs.shouldReturnInvalidMagicValue) {
            //     if (
            //         !context.fulfillArgs.shouldIncludeNativeConsideration
            //         // If the fuzz args pick this address as the consideration
            //         // recipient, then the ERC20 transfers and the native token
            //         // transfers will be filtered, so there will be no events.
            //         && address(context.fulfillArgs.considerationRecipient)
            //             != address(this)
            //     ) {
            //         // This checks that the ERC20 transfers were not all aggregated
            //         // into a single transfer.
            //         vm.expectEmit(true, true, false, true, address(token1));
            //         emit Transfer(
            //             address(this), // from
            //             address(context.fulfillArgs.considerationRecipient), // to
            //             // The value should in the transfer event should either be
            //             // the amount * the number of NFTs for sale (if aggregating) or
            //             // the amount (if not aggregating).
            //             context.fulfillArgs.amount
            //                 * (
            //                     context.fulfillArgs.shouldAggregateFulfillmentComponents
            //                         ? context.fulfillArgs.maximumFulfilledCount
            //                         : 1
            //                 )
            //         );

            //         if (context.fulfillArgs.considerationItemsPerOrderCount >= 2) {
            //             // This checks that the second consideration item is being
            //             // properly handled.
            //             vm.expectEmit(true, true, false, true, address(token2));
            //             emit Transfer(
            //                 address(this), // from
            //                 address(context.fulfillArgs.considerationRecipient), // to
            //                 context.fulfillArgs.amount
            //                     * (
            //                         context.fulfillArgs.shouldAggregateFulfillmentComponents
            //                             ? context.fulfillArgs.maximumFulfilledCount
            //                             : 1
            //                     ) // value
            //             );
            //         }
            //     }
            // }
        }

        // // Set up revert expectations.
        // if (context.fulfillArgs.shouldReturnInvalidMagicValue) {
        //     TODO: Get the poison orderHash.
        //     vm.expectRevert(
        //         abi.encodeWithSignature("InvalidRestrictedOrder(bytes32)", bytes32(0))
        //     );
        // } else if (context.fulfillArgs.shouldRevert) {
        //     TODO: Set up expectations for the mix of skips and fulfillments.
        // }

        // Make the call to Seaport. When the fuzz args call for using native
        // consideration, send enough native tokens to cover the amount per sale
        // * the number of sales.  Otherwise, send just the excess native
        // tokens.
        context.seaport.fulfillAvailableAdvancedOrders{
            value: context.fulfillArgs.excessNativeTokens
                + (
                    context.fulfillArgs.shouldIncludeNativeConsideration
                        ? context.fulfillArgs.amount
                            * context.fulfillArgs.maximumFulfilledCount
                        : 0
                )
        }({
            advancedOrders: infra.advancedOrders,
            criteriaResolvers: infra.criteriaResolvers,
            offerFulfillments: infra.offerFulfillmentComponents,
            considerationFulfillments: infra.considerationFulfillmentComponents,
            fulfillerConduitKey: bytes32(conduitKey),
            // If the fuzz args call for specifying a recipient, pass in the
            // offer recipient.  Otherwise, pass in the null address, which
            // sets the caller as the recipient.
            recipient: context.fulfillArgs.shouldSpecifyRecipient
                ? context.fulfillArgs.offerRecipient
                : address(0),
            maximumFulfilled: context.fulfillArgs.maximumFulfilledCount
        });

        ////////////////////////////////////////////////////////////////////////
        //                                                                    //
        // This commented out code below if from                              //
        // TestTransferValidationZoneOffererTest. It'll eventually be used to //
        // test the happy path. It can be ignored entirely for now.           //
        //                                                                    //
        ////////////////////////////////////////////////////////////////////////

        // // Store balances after the call for later comparison.
        // infra.callerBalanceAfter = address(this).balance;
        // infra.considerationRecipientNativeBalanceAfter =
        //     address(context.fulfillArgs.considerationRecipient).balance;
        // infra.considerationRecipientToken1BalanceAfter =
        //     token1.balanceOf(context.fulfillArgs.considerationRecipient);
        // infra.considerationRecipientToken2BalanceAfter =
        //     token2.balanceOf(context.fulfillArgs.considerationRecipient);

        // // Check that the NFTs were transferred to the expected recipient.
        // for (uint256 i = 0; i < context.fulfillArgs.maximumFulfilledCount; i++)
        // {
        //     assertEq(
        //         test721_1.ownerOf(context.fulfillArgs.tokenId + i),
        //         context.fulfillArgs.shouldSpecifyRecipient
        //             ? context.fulfillArgs.offerRecipient
        //             : address(this),
        //         "NFT owner incorrect."
        //     );
        // }

        // // Check that the ERC20s or native tokens were transferred to the
        // // expected recipient according to the fuzz args.
        // if (context.fulfillArgs.shouldIncludeNativeConsideration) {
        //     if (
        //         address(context.fulfillArgs.considerationRecipient)
        //             == address(this)
        //     ) {
        //         // Edge case: If the fuzz args pick this address for the
        //         // consideration recipient, then the caller's balance should not
        //         // change.
        //         assertEq(
        //             infra.callerBalanceAfter,
        //             infra.callerBalanceBefore,
        //             "Caller balance incorrect (this contract)."
        //         );
        //     } else {
        //         // Check that the consideration recipient's native balance was
        //         // increased by the amount * the number of NFTs for sale.
        //         assertEq(
        //             infra.considerationRecipientNativeBalanceAfter,
        //             infra.considerationRecipientNativeBalanceBefore
        //                 + context.fulfillArgs.amount
        //                     * context.fulfillArgs.maximumFulfilledCount,
        //             "Consideration recipient native balance incorrect."
        //         );
        //         // The consideration (amount * maximumFulfilledCount) should be
        //         // spent, and the excessNativeTokens should be returned.
        //         assertEq(
        //             infra.callerBalanceAfter
        //                 + context.fulfillArgs.amount
        //                     * context.fulfillArgs.maximumFulfilledCount,
        //             infra.callerBalanceBefore,
        //             "Caller balance incorrect."
        //         );
        //     }
        // } else {
        //     // The `else` here is the case where no native consieration is used.
        //     if (
        //         address(context.fulfillArgs.considerationRecipient)
        //             == address(this)
        //     ) {
        //         // Edge case: If the fuzz args pick this address for the
        //         // consideration recipient, then the caller's balance should not
        //         // change.
        //         assertEq(
        //             infra.considerationRecipientToken1BalanceAfter,
        //             infra.considerationRecipientToken1BalanceBefore,
        //             "Consideration recipient token1 balance incorrect (this)."
        //         );
        //     } else {
        //         assertEq(
        //             infra.considerationRecipientToken1BalanceAfter,
        //             infra.considerationRecipientToken1BalanceBefore
        //                 + context.fulfillArgs.amount
        //                     * context.fulfillArgs.maximumFulfilledCount,
        //             "Consideration recipient token1 balance incorrect."
        //         );
        //     }

        //     if (context.fulfillArgs.considerationItemsPerOrderCount >= 2) {
        //         if (
        //             address(context.fulfillArgs.considerationRecipient)
        //                 == address(this)
        //         ) {
        //             // Edge case: If the fuzz args pick this address for the
        //             // consideration recipient, then the caller's balance should
        //             // not change.
        //             assertEq(
        //                 infra.considerationRecipientToken2BalanceAfter,
        //                 infra.considerationRecipientToken2BalanceBefore,
        //                 "Consideration recipient token2 balance incorrect (this)."
        //             );
        //         } else {
        //             assertEq(
        //                 infra.considerationRecipientToken2BalanceAfter,
        //                 infra.considerationRecipientToken2BalanceBefore
        //                     + context.fulfillArgs.amount
        //                         * context.fulfillArgs.maximumFulfilledCount,
        //                 "Consideration recipient token2 balance incorrect."
        //             );
        //         }
        //     }
        // }
    }

    ////////////////////////////////////////////////////////////////////////////
    //                                                                        //
    // Pretty much everything below here can be ignored. It's all just very   //
    // lightly modified code from `TestTransferValidationZoneOffererTest`,    //
    // which is pretty stable.                                                //
    //                                                                        //
    ////////////////////////////////////////////////////////////////////////////

    function _buildOrdersFromFuzzArgs(Context memory context, uint256 key, address verboseZoneAddress)
        internal
        view
        returns (AdvancedOrder[] memory advancedOrders)
    {
        // Create the OrderComponents array from the fuzz args.
        OrderComponents[] memory orderComponents;
        orderComponents = _buildOrderComponentsArrayFromFuzzArgs(context, verboseZoneAddress);

        // Set up the AdvancedOrder array.
        AdvancedOrder[] memory _advancedOrders = new AdvancedOrder[](
            context.fulfillArgs.orderCount
        );

        // Iterate over the OrderComponents array and build an AdvancedOrder
        // for each OrderComponents.
        Order memory order;
        for (uint256 i = 0; i < orderComponents.length; i++) {
            if (orderComponents[i].orderType == OrderType.CONTRACT) {
                revert("Not implemented.");
            } else {
                // Create the order.
                order = _toOrder(context.seaport, orderComponents[i], key);
                // Convert it to an AdvancedOrder and add it to the array.
                _advancedOrders[i] = order.toAdvancedOrder(
                    1,
                    1,
                    // Reusing salt here for junk data.
                    context.fulfillArgs.shouldIncludeJunkDataInAdvancedOrder
                        ? bytes(abi.encodePacked(context.fulfillArgs.salt))
                        : bytes("")
                );
            }
        }

        return _advancedOrders;
    }

    function _buildOrdersAndFulfillmentsMirrorOrdersFromFuzzArgs(
        Context memory context,
        address verboseZoneAddress
    ) internal returns (Order[] memory, Fulfillment[] memory) {
        uint256 i;

        // Set up the OrderAndFulfillmentInfra struct.
        OrderAndFulfillmentInfra memory infra = OrderAndFulfillmentInfra(
            new OfferItem[](context.matchArgs.orderPairCount),
            new ConsiderationItem[](context.matchArgs.orderPairCount),
            OrderComponentsLib.empty(),
            new Order[](context.matchArgs.orderPairCount * 2),
            FulfillmentLib.empty(),
            new Fulfillment[](context.matchArgs.orderPairCount * 2)
        );

        // Iterate once for each orderPairCount, which is
        // used as the number of order pairs to make here.
        for (i = 0; i < context.matchArgs.orderPairCount; i++) {
            // Mint the NFTs for the prime offerer to sell.
            test721_1.mint(fuzzPrimeOfferer.addr, context.matchArgs.tokenId + i);
            test721_1.mint(
                fuzzPrimeOfferer.addr, (context.matchArgs.tokenId + i) * 2
            );

            // Build the OfferItem array for the prime offerer's order.
            infra.offerItemArray = _buildPrimeOfferItemArray(context, i);
            // Build the ConsiderationItem array for the prime offerer's order.
            infra.considerationItemArray =
                _buildPrimeConsiderationItemArray(context);

            // Build the OrderComponents for the prime offerer's order.
            infra.orderComponents = _buildOrderComponents(
                context,
                infra.offerItemArray,
                infra.considerationItemArray,
                fuzzPrimeOfferer.addr,
                verboseZoneAddress
            );

            // Add the order to the orders array.
            infra.orders[i] = _toOrder(
                context.seaport, infra.orderComponents, fuzzPrimeOfferer.key
            );

            // Build the offerItemArray for the mirror offerer's order.
            infra.offerItemArray = _buildMirrorOfferItemArray(context);

            // Build the considerationItemArray for the mirror offerer's order.
            // Note that the consideration on the mirror is always just one NFT,
            // even if the prime order has an excess item.
            infra.considerationItemArray =
                buildMirrorConsiderationItemArray(context, i);

            // Build the OrderComponents for the mirror offerer's order.
            infra.orderComponents = _buildOrderComponents(
                context,
                infra.offerItemArray,
                infra.considerationItemArray,
                fuzzMirrorOfferer.addr,
                verboseZoneAddress
            );

            // Create the order and add the order to the orders array.
            infra.orders[i + context.matchArgs.orderPairCount] = _toOrder(
                context.seaport, infra.orderComponents, fuzzMirrorOfferer.key
            );
        }

        bytes32[] memory orderHashes = new bytes32[](
            context.matchArgs.orderPairCount * 2
        );

        UnavailableReason[] memory unavailableReasons = new UnavailableReason[](
            context.matchArgs.orderPairCount * 2
        );

        // Build fulfillments.
        (infra.fulfillments,,) = matchFulfillmentHelper.getMatchedFulfillments(
            infra.orders, orderHashes, unavailableReasons
        );

        return (infra.orders, infra.fulfillments);
    }

    function _buildPrimeOfferItemArray(Context memory context, uint256 i)
        internal
        view
        returns (OfferItem[] memory _offerItemArray)
    {
        // Set up the OfferItem array.
        OfferItem[] memory offerItemArray = new OfferItem[](
            context.matchArgs.shouldIncludeExcessOfferItems ? 2 : 1
        );

        // If the fuzz args call for an excess offer item...
        if (context.matchArgs.shouldIncludeExcessOfferItems) {
            // Create the OfferItem array containing the offered item and the
            // excess item.
            offerItemArray = SeaportArrays.OfferItems(
                OfferItemLib.fromDefault(SINGLE_721).withToken(
                    address(test721_1)
                ).withIdentifierOrCriteria(context.matchArgs.tokenId + i),
                OfferItemLib.fromDefault(SINGLE_721).withToken(
                    address(test721_1)
                ).withIdentifierOrCriteria((context.matchArgs.tokenId + i) * 2)
            );
        } else {
            // Otherwise, create the OfferItem array containing the one offered
            // item.
            offerItemArray = SeaportArrays.OfferItems(
                OfferItemLib.fromDefault(SINGLE_721).withToken(
                    address(test721_1)
                ).withIdentifierOrCriteria(context.matchArgs.tokenId + i)
            );
        }

        return offerItemArray;
    }

    function _buildPrimeConsiderationItemArray(Context memory context)
        internal
        view
        returns (ConsiderationItem[] memory _considerationItemArray)
    {
        // Set up the ConsiderationItem array.
        ConsiderationItem[] memory considerationItemArray =
        new ConsiderationItem[](
                context.matchArgs.considerationItemsPerPrimeOrderCount
            );

        // Create the consideration items.
        (
            ConsiderationItem memory nativeConsiderationItem,
            ConsiderationItem memory erc20ConsiderationItemOne,
            ConsiderationItem memory erc20ConsiderationItemTwo
        ) = _createReusableConsiderationItems(
            context.matchArgs.amount, fuzzPrimeOfferer.addr
        );

        if (context.matchArgs.considerationItemsPerPrimeOrderCount == 1) {
            // If the fuzz args call for native consideration...
            if (context.matchArgs.shouldIncludeNativeConsideration) {
                // ...add a native consideration item...
                considerationItemArray =
                    SeaportArrays.ConsiderationItems(nativeConsiderationItem);
            } else {
                // ...otherwise, add an ERC20 consideration item.
                considerationItemArray =
                    SeaportArrays.ConsiderationItems(erc20ConsiderationItemOne);
            }
        } else if (context.matchArgs.considerationItemsPerPrimeOrderCount == 2)
        {
            // If the fuzz args call for native consideration...
            if (context.matchArgs.shouldIncludeNativeConsideration) {
                // ...add a native consideration item and an ERC20
                // consideration item...
                considerationItemArray = SeaportArrays.ConsiderationItems(
                    nativeConsiderationItem, erc20ConsiderationItemOne
                );
            } else {
                // ...otherwise, add two ERC20 consideration items.
                considerationItemArray = SeaportArrays.ConsiderationItems(
                    erc20ConsiderationItemOne, erc20ConsiderationItemTwo
                );
            }
        } else {
            // If the fuzz args call for three consideration items per prime
            // order, add all three consideration items.
            considerationItemArray = SeaportArrays.ConsiderationItems(
                nativeConsiderationItem,
                erc20ConsiderationItemOne,
                erc20ConsiderationItemTwo
            );
        }

        return considerationItemArray;
    }

    function _buildOrderComponentsArrayFromFuzzArgs(
        Context memory context,
        address verboseZoneAddress
    )
        internal
        view
        returns (OrderComponents[] memory _orderComponentsArray)
    {
        // Set up the OrderComponentInfra struct.
        OrderComponentInfra memory orderComponentInfra = OrderComponentInfra(
            OrderComponentsLib.empty(),
            new OrderComponents[](context.fulfillArgs.orderCount),
            new OfferItem[][](context.fulfillArgs.orderCount),
            new ConsiderationItem[][](context.fulfillArgs.orderCount),
            ConsiderationItemLib.empty(),
            ConsiderationItemLib.empty(),
            ConsiderationItemLib.empty()
        );

        // Create three different consideration items.
        (
            orderComponentInfra.nativeConsiderationItem,
            orderComponentInfra.erc20ConsiderationItemOne,
            orderComponentInfra.erc20ConsiderationItemTwo
        ) = _createReusableConsiderationItems(
            context.fulfillArgs.amount,
            context.fulfillArgs.considerationRecipient
        );

        // Iterate once for each order and create the OfferItems[] and
        // ConsiderationItems[] for each order.
        for (uint256 i; i < context.fulfillArgs.orderCount; i++) {
            // Add a one-element OfferItems[] to the OfferItems[][].
            orderComponentInfra.offerItemArray[i] = SeaportArrays.OfferItems(
                OfferItemLib.fromDefault(SINGLE_721).withToken(
                    address(test721_1)
                ).withIdentifierOrCriteria(context.fulfillArgs.tokenId + i)
            );

            if (context.fulfillArgs.considerationItemsPerOrderCount == 1) {
                // If the fuzz args call for native consideration...
                if (context.fulfillArgs.shouldIncludeNativeConsideration) {
                    // ...add a native consideration item...
                    orderComponentInfra.considerationItemArray[i] =
                    SeaportArrays.ConsiderationItems(
                        orderComponentInfra.nativeConsiderationItem
                    );
                } else {
                    // ...otherwise, add an ERC20 consideration item.
                    orderComponentInfra.considerationItemArray[i] =
                    SeaportArrays.ConsiderationItems(
                        orderComponentInfra.erc20ConsiderationItemOne
                    );
                }
            } else if (context.fulfillArgs.considerationItemsPerOrderCount == 2)
            {
                // If the fuzz args call for native consideration...
                if (context.fulfillArgs.shouldIncludeNativeConsideration) {
                    // ...add a native consideration item and an ERC20
                    // consideration item...
                    orderComponentInfra.considerationItemArray[i] =
                    SeaportArrays.ConsiderationItems(
                        orderComponentInfra.nativeConsiderationItem,
                        orderComponentInfra.erc20ConsiderationItemOne
                    );
                } else {
                    // ...otherwise, add two ERC20 consideration items.
                    orderComponentInfra.considerationItemArray[i] =
                    SeaportArrays.ConsiderationItems(
                        orderComponentInfra.erc20ConsiderationItemOne,
                        orderComponentInfra.erc20ConsiderationItemTwo
                    );
                }
            } else {
                orderComponentInfra.considerationItemArray[i] = SeaportArrays
                    .ConsiderationItems(
                    orderComponentInfra.nativeConsiderationItem,
                    orderComponentInfra.erc20ConsiderationItemOne,
                    orderComponentInfra.erc20ConsiderationItemTwo
                );
            }
        }

        bytes32 conduitKey;

        // Iterate once for each order and create the OrderComponents.
        for (uint256 i = 0; i < context.fulfillArgs.orderCount; i++) {
            // if context.fulfillArgs.shouldUseConduit is false: don't use conduits at all.
            // if context.fulfillArgs.shouldUseConduit is true:
            //      if context.fulfillArgs.tokenId % 2 == 0:
            //          use conduits for some and not for others
            //      if context.fulfillArgs.tokenId % 2 != 0:
            //          use conduits for all
            // This is plainly deranged, but it allows for conduit use
            // for all, for some, and none without weighing down the stack.
            conduitKey = !context.fulfillArgs.shouldIncludeNativeConsideration
                && context.fulfillArgs.shouldUseConduit
                && (context.fulfillArgs.tokenId % 2 == 0 ? i % 2 == 0 : true)
                ? conduitKeyOne
                : bytes32(0);

            // Build the order components.
            orderComponentInfra.orderComponents = OrderComponentsLib.fromDefault(
                STD_RESTRICTED
            ).withOffer(orderComponentInfra.offerItemArray[i]).withConsideration(
                orderComponentInfra.considerationItemArray[i]
            ).withZone(verboseZoneAddress).withZoneHash(context.fulfillArgs.zoneHash)
                .withConduitKey(conduitKey).withSalt(
                context.fulfillArgs.salt % (i + 1)
            ); // Is this dumb?

            // Add the OrderComponents to the OrderComponents[].
            orderComponentInfra.orderComponentsArray[i] =
                orderComponentInfra.orderComponents;
        }

        // Return the OrderComponents[].
        return orderComponentInfra.orderComponentsArray;
    }

    function _buildOrderComponents(
        Context memory context,
        OfferItem[] memory offerItemArray,
        ConsiderationItem[] memory considerationItemArray,
        address offerer,
        address verboseZoneAddress
    ) internal view returns (OrderComponents memory _orderComponents) {
        OrderComponents memory orderComponents = OrderComponentsLib.empty();

        // Create the offer and consideration item arrays.
        OfferItem[] memory _offerItemArray = offerItemArray;
        ConsiderationItem[] memory _considerationItemArray =
            considerationItemArray;

        // Build the OrderComponents for the prime offerer's order.
        orderComponents = OrderComponentsLib.fromDefault(STD_RESTRICTED)
            .withOffer(_offerItemArray).withConsideration(_considerationItemArray)
            .withZone(verboseZoneAddress).withOrderType(OrderType.FULL_OPEN).withConduitKey(
            context.matchArgs.tokenId % 2 == 0 ? conduitKeyOne : bytes32(0)
        ).withOfferer(offerer).withCounter(context.seaport.getCounter(offerer));


        // ... set the zone to the verboseZone and set the order type to
        // FULL_RESTRICTED.
        orderComponents = orderComponents.copy().withZone(verboseZoneAddress)
            .withOrderType(OrderType.FULL_RESTRICTED);
        

        return orderComponents;
    }

    function _toOrder(
        ConsiderationInterface seaport,
        OrderComponents memory orderComponents,
        uint256 pkey
    ) internal view returns (Order memory order) {
        bytes32 orderHash = seaport.getOrderHash(orderComponents);
        bytes memory signature = signOrder(seaport, pkey, orderHash);
        order = OrderLib.empty().withParameters(
            orderComponents.toOrderParameters()
        ).withSignature(signature);
    }

    function _buildMirrorOfferItemArray(Context memory context)
        internal
        view
        returns (OfferItem[] memory _offerItemArray)
    {
        // Set up the OfferItem array.
        OfferItem[] memory offerItemArray = new OfferItem[](1);

        // Create some consideration items.
        (
            ConsiderationItem memory nativeConsiderationItem,
            ConsiderationItem memory erc20ConsiderationItemOne,
            ConsiderationItem memory erc20ConsiderationItemTwo
        ) = _createReusableConsiderationItems(
            context.matchArgs.amount, fuzzPrimeOfferer.addr
        );

        // Convert them to OfferItems.
        OfferItem memory nativeOfferItem = nativeConsiderationItem.toOfferItem();
        OfferItem memory erc20OfferItemOne =
            erc20ConsiderationItemOne.toOfferItem();
        OfferItem memory erc20OfferItemTwo =
            erc20ConsiderationItemTwo.toOfferItem();

        if (context.matchArgs.considerationItemsPerPrimeOrderCount == 1) {
            // If the fuzz args call for native consideration...
            if (context.matchArgs.shouldIncludeNativeConsideration) {
                // ...add a native consideration item...
                offerItemArray = SeaportArrays.OfferItems(nativeOfferItem);
            } else {
                // ...otherwise, add an ERC20 consideration item.
                offerItemArray = SeaportArrays.OfferItems(erc20OfferItemOne);
            }
        } else if (context.matchArgs.considerationItemsPerPrimeOrderCount == 2)
        {
            // If the fuzz args call for native consideration...
            if (context.matchArgs.shouldIncludeNativeConsideration) {
                // ...add a native consideration item and an ERC20
                // consideration item...
                offerItemArray =
                    SeaportArrays.OfferItems(nativeOfferItem, erc20OfferItemOne);
            } else {
                // ...otherwise, add two ERC20 consideration items.
                offerItemArray = SeaportArrays.OfferItems(
                    erc20OfferItemOne, erc20OfferItemTwo
                );
            }
        } else {
            offerItemArray = SeaportArrays.OfferItems(
                nativeOfferItem, erc20OfferItemOne, erc20OfferItemTwo
            );
        }

        return offerItemArray;
    }

    function buildMirrorConsiderationItemArray(
        Context memory context,
        uint256 i
    )
        internal
        view
        returns (ConsiderationItem[] memory _considerationItemArray)
    {
        // Set up the ConsiderationItem array.
        ConsiderationItem[] memory considerationItemArray =
        new ConsiderationItem[](
                context.matchArgs.considerationItemsPerPrimeOrderCount
            );

        // Note that the consideration array here will always be just one NFT
        // so because the second NFT on the offer side is meant to be excess.
        considerationItemArray = SeaportArrays.ConsiderationItems(
            ConsiderationItemLib.fromDefault(SINGLE_721).withToken(
                address(test721_1)
            ).withIdentifierOrCriteria(context.matchArgs.tokenId + i)
                .withRecipient(fuzzMirrorOfferer.addr)
        );

        return considerationItemArray;
    }

     function _createReusableConsiderationItems(
        uint256 amount,
        address recipient
    )
        internal
        view
        returns (
            ConsiderationItem memory nativeConsiderationItem,
            ConsiderationItem memory erc20ConsiderationItemOne,
            ConsiderationItem memory erc20ConsiderationItemTwo
        )
    {
        // Create a reusable native consideration item.
        nativeConsiderationItem = ConsiderationItemLib.empty().withItemType(
            ItemType.NATIVE
        ).withIdentifierOrCriteria(0).withStartAmount(amount).withEndAmount(
            amount
        ).withRecipient(recipient);

        // Create a reusable ERC20 consideration item.
        erc20ConsiderationItemOne = ConsiderationItemLib.empty().withItemType(
            ItemType.ERC20
        ).withToken(address(token1)).withIdentifierOrCriteria(0).withStartAmount(
            amount
        ).withEndAmount(amount).withRecipient(recipient);

        // Create a second reusable ERC20 consideration item.
        erc20ConsiderationItemTwo = ConsiderationItemLib.empty().withItemType(
            ItemType.ERC20
        ).withIdentifierOrCriteria(0).withToken(address(token2)).withStartAmount(
            amount
        ).withEndAmount(amount).withRecipient(recipient);
    }

    function _boundMatchArgs(MatchFuzzInputs memory matchArgs)
        internal
        returns (MatchFuzzInputs memory)
    {
        // Avoid weird overflow issues.
        matchArgs.amount =
            uint128(bound(matchArgs.amount, 1, 0xffffffffffffffff));
        // Avoid trying to mint the same token.
        matchArgs.tokenId = bound(matchArgs.tokenId, 0xff, 0xffffffffffffffff);
        // Make 2-8 order pairs per call.  Each order pair will have 1-2 offer
        // items on the prime side (depending on whether
        // shouldIncludeExcessOfferItems is true or false).
        matchArgs.orderPairCount = bound(matchArgs.orderPairCount, 2, 8);
        // Use 1-3 (prime) consideration items per order.
        matchArgs.considerationItemsPerPrimeOrderCount =
            bound(matchArgs.considerationItemsPerPrimeOrderCount, 1, 3);
        // To put three items in the consideration, native tokens must be
        // included.
        matchArgs.shouldIncludeNativeConsideration = matchArgs
            .shouldIncludeNativeConsideration
            || matchArgs.considerationItemsPerPrimeOrderCount >= 3;
        // Include some excess native tokens to check that they're ending up
        // with the caller afterward.
        matchArgs.excessNativeTokens = uint128(
            bound(
                matchArgs.excessNativeTokens, 0, 0xfffffffffffffffffffffffffffff
            )
        );
        // Don't set the offer recipient to the null address, because that's the
        // way to indicate that the caller should be the recipient.
        matchArgs.unspentPrimeOfferItemRecipient = _nudgeAddressIfProblematic(
            address(
                uint160(
                    bound(
                        uint160(matchArgs.unspentPrimeOfferItemRecipient),
                        1,
                        type(uint160).max
                    )
                )
            )
        );

        matchArgs.shouldRevert = matchArgs.shouldRevert
            && !matchArgs.shouldReturnInvalidMagicValue;

        return matchArgs;
    }

    function _boundFulfillArgs(FulfillFuzzInputs memory fulfillArgs)
        internal
        returns (FulfillFuzzInputs memory)
    {
        // Limit this value to avoid overflow issues.
        fulfillArgs.amount =
            uint128(bound(fulfillArgs.amount, 1, 0xffffffffffffffff));
        // Limit this value to avoid overflow issues.
        fulfillArgs.tokenId = bound(fulfillArgs.tokenId, 1, 0xffffffffffffffff);
        // Create between 2 and 16 orders.
        fulfillArgs.orderCount = bound(fulfillArgs.orderCount, 4, 16);
        // Use between 1 and 3 consideration items per order.
        fulfillArgs.considerationItemsPerOrderCount =
            bound(fulfillArgs.considerationItemsPerOrderCount, 1, 3);
        // To put three items in the consideration, native tokens must be
        // included.
        fulfillArgs.shouldIncludeNativeConsideration = fulfillArgs
            .shouldIncludeNativeConsideration
            || fulfillArgs.considerationItemsPerOrderCount >= 3;
        // Fulfill between 2 and the orderCount.
        fulfillArgs.maximumFulfilledCount =
            bound(fulfillArgs.maximumFulfilledCount, 2, fulfillArgs.orderCount);
        // Limit this value to avoid overflow issues.
        fulfillArgs.excessNativeTokens = uint128(
            bound(
                fulfillArgs.excessNativeTokens,
                0,
                0xfffffffffffffffffffffffffffff
            )
        );
        // Don't set the offer recipient to the null address, because that's the
        // way to indicate that the caller should be the recipient and because
        // some tokens refuse to transfer to the null address.
        fulfillArgs.offerRecipient = _nudgeAddressIfProblematic(
            address(
                uint160(
                    bound(
                        uint160(fulfillArgs.offerRecipient),
                        1,
                        type(uint160).max
                    )
                )
            )
        );
        // Don't set the consideration recipient to the null address, because
        // some tokens refuse to transfer to the null address.
        fulfillArgs.considerationRecipient = _nudgeAddressIfProblematic(
            address(
                uint160(
                    bound(
                        uint160(fulfillArgs.considerationRecipient),
                        1,
                        type(uint160).max
                    )
                )
            )
        );

        fulfillArgs.shouldRevert = fulfillArgs.shouldRevert
            && !fulfillArgs.shouldReturnInvalidMagicValue;

        return fulfillArgs;
    }

    function _nudgeAddressIfProblematic(address _address)
        internal
        returns (address)
    {
        bool success;
        assembly {
            // Transfer the native token and store if it succeeded or not.
            success := call(gas(), _address, 1, 0, 0, 0, 0)
        }

        if (success) {
            return _address;
        } else {
            return address(uint160(_address) + 1);
        }
    }
}
