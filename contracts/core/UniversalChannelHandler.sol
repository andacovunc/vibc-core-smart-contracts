//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.9;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IbcDispatcher} from "../interfaces/IbcDispatcher.sol";
import {
    IbcMiddleware,
    IbcUniversalChannelMW,
    IbcUniversalPacketReceiver,
    IbcMwPacketReceiver,
    IbcMwEventsEmitter
} from "../interfaces/IbcMiddleware.sol";
import {IbcReceiver, IbcReceiverBase} from "../interfaces/IbcReceiver.sol";
import {ChannelOrder, CounterParty, IbcPacket, AckPacket, UniversalPacket, IbcUtils} from "../libs/Ibc.sol";

contract UniversalChannelHandler is IbcReceiverBase, IbcUniversalChannelMW {
    bytes32[] public connectedChannels;
    string public constant VERSION = "1.0";
    uint256 public constant MW_ID = 1;

    // Key: middleware bitmap, Value: middleware address from receiver(chain B)'s perspective
    mapping(uint256 => address[]) public mwStackAddrs;

    constructor(IbcDispatcher _dispatcher) IbcReceiverBase(_dispatcher) {}
    /**
     * @dev Close a universal channel.
     * Cannot send or receive packets after the channel is closed.
     * @param channelId The channel id of the channel to be closed.
     */

    function closeChannel(bytes32 channelId) external onlyOwner {
        dispatcher.closeIbcChannel(channelId);
    }

    function onCloseIbcChannel(bytes32 channelId, string calldata, bytes32) external onlyIbcDispatcher {
        // logic to determin if the channel should be closed
        bool channelFound = false;
        for (uint256 i = 0; i < connectedChannels.length; i++) {
            if (connectedChannels[i] == channelId) {
                delete connectedChannels[i];
                channelFound = true;
                break;
            }
        }
        if (!channelFound) revert ChannelNotFound();
    }

    function sendUniversalPacket(
        bytes32 channelId,
        bytes32 destPortAddr,
        bytes calldata appData,
        uint64 timeoutTimestamp
    ) external {
        bytes memory packetData = IbcUtils.toUniversalPacketBytes(
            UniversalPacket(IbcUtils.toBytes32(msg.sender), MW_ID, destPortAddr, appData)
        );
        dispatcher.sendPacket(channelId, packetData, timeoutTimestamp);
    }

    // called by another IBC middleware; pack packet and send over to Dispatcher
    function sendMWPacket(
        bytes32 channelId,
        // original source address of the packet
        bytes32 srcPortAddr,
        bytes32 destPortAddr,
        // source middleware ids bit AND
        uint256 srcMwIds,
        bytes calldata appData,
        uint64 timeoutTimestamp
    ) external {
        bytes memory packetData =
            IbcUtils.toUniversalPacketBytes(UniversalPacket(srcPortAddr, srcMwIds | MW_ID, destPortAddr, appData));
        dispatcher.sendPacket(channelId, packetData, timeoutTimestamp);
    }

    function onRecvPacket(IbcPacket calldata packet)
        external
        override
        onlyIbcDispatcher
        returns (AckPacket memory ackPacket)
    {
        UniversalPacket memory ucPacket = IbcUtils.fromUniversalPacketBytes(packet.data);
        address[] storage mwAddrs = mwStackAddrs[ucPacket.mwBitmap];
        if (mwAddrs.length == 0) {
            // no other middleware stack registered for this packet. Deliver packet to dApp directly.
            return IbcUniversalPacketReceiver(IbcUtils.toAddress(ucPacket.destPortAddr)).onRecvUniversalPacket(
                packet.dest.channelId, ucPacket
            );
        } else {
            // send packet to first MW in the stack
            return IbcMwPacketReceiver(mwAddrs[0]).onRecvMWPacket(packet.dest.channelId, ucPacket, 0, mwAddrs);
        }
    }

    function onAcknowledgementPacket(IbcPacket calldata packet, AckPacket calldata ack)
        external
        override
        onlyIbcDispatcher
    {
        UniversalPacket memory ucPacket = IbcUtils.fromUniversalPacketBytes(packet.data);
        address[] storage mwAddrs = mwStackAddrs[ucPacket.mwBitmap];
        if (mwAddrs.length == 0) {
            // no other middleware stack registered for this packet. Deliver ack to dApp directly.
            IbcUniversalPacketReceiver(IbcUtils.toAddress(ucPacket.srcPortAddr)).onUniversalAcknowledgement(
                packet.src.channelId, ucPacket, ack
            );
        } else {
            // send ack to last MW in the stack
            IbcMwPacketReceiver(mwAddrs[0]).onRecvMWAck(packet.src.channelId, ucPacket, 0, mwAddrs, ack);
        }
    }

    function onTimeoutPacket(IbcPacket calldata packet) external override onlyIbcDispatcher {
        UniversalPacket memory ucPacketData = IbcUtils.fromUniversalPacketBytes(packet.data);
        address[] storage mwAddrs = mwStackAddrs[ucPacketData.mwBitmap];
        if (mwAddrs.length == 0) {
            // no other middleware stack registered for this packet. Deliver timeout to dApp directly.
            IbcUniversalPacketReceiver(IbcUtils.toAddress(ucPacketData.srcPortAddr)).onTimeoutUniversalPacket(
                packet.src.channelId, ucPacketData
            );
        } else {
            // send timeout to last MW in the stack
            IbcMwPacketReceiver(mwAddrs[0]).onRecvMWTimeout(packet.src.channelId, ucPacketData, 0, mwAddrs);
        }
    }

    /**
     * @dev Register a middleware stack for universal packet routing.
     * This is a temporary solution for testing only.
     * Polymer chain will maintain a global registry of middleware stacks.
     * @param mwBitmap Bit OR of all MW IDs in the stack, excluding this MW's ID
     * @param mwAddrs addresses in the stack, from the perspective of the receiver (chain B)
     * MW closer to UniversalChannel MW has smaller index. MW stack must be in the same order on both chains.
     */
    function registerMwStack(uint256 mwBitmap, address[] calldata mwAddrs) external onlyOwner {
        if (mwBitmap == 0) revert MwBitmpaCannotBeZero();
        mwStackAddrs[mwBitmap] = mwAddrs;
    }

    // IBC callback functions
    function onChanOpenAck(bytes32 channelId, string calldata counterpartyVersion) external onlyIbcDispatcher {
        _connectChannel(channelId, counterpartyVersion);
    }

    function onChanOpenConfirm(bytes32 channelId, string calldata counterpartyVersion) external onlyIbcDispatcher {
        _connectChannel(channelId, counterpartyVersion);
    }

    function onChanOpenInit(string calldata version)
        external
        view
        onlyIbcDispatcher
        returns (string memory selectedVersion)
    {
        return _openChannel(version);
    }

    function onChanOpenTry(string calldata counterpartyVersion)
        external
        view
        onlyIbcDispatcher
        returns (string memory selectedVersion)
    {
        return _openChannel(counterpartyVersion);
    }

    function _connectChannel(bytes32 channelId, string calldata version) private {
        if (keccak256(abi.encodePacked(version)) != keccak256(abi.encodePacked(VERSION))) {
            revert UnsupportedVersion();
        }
        connectedChannels.push(channelId);
    }

    function _openChannel(string calldata version) private pure returns (string memory selectedVersion) {
        if (keccak256(abi.encodePacked(version)) != keccak256(abi.encodePacked(VERSION))) {
            revert UnsupportedVersion();
        }
        return VERSION;
    }
}
