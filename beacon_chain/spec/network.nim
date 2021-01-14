# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[strformat, sets, random],
  ./datatypes, ./helpers, ./validator

const
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#topics-and-messages
  topicBeaconBlocksSuffix* = "beacon_block/ssz"
  topicVoluntaryExitsSuffix* = "voluntary_exit/ssz"
  topicProposerSlashingsSuffix* = "proposer_slashing/ssz"
  topicAttesterSlashingsSuffix* = "attester_slashing/ssz"
  topicAggregateAndProofsSuffix* = "beacon_aggregate_and_proof/ssz"

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#misc
  ATTESTATION_SUBNET_COUNT* = 64

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#eth2-network-interaction-domains
  MAX_CHUNK_SIZE* = 1 * 1024 * 1024 # bytes
  GOSSIP_MAX_SIZE* = 1 * 1024 * 1024 # bytes
  TTFB_TIMEOUT* = 5.seconds
  RESP_TIMEOUT* = 10.seconds

  defaultEth2TcpPort* = 9000

  # This is not part of the spec yet! Keep in sync with BASE_RPC_PORT
  defaultEth2RpcPort* = 9190

func getBeaconBlocksTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicBeaconBlocksSuffix}"
  except ValueError as e:
    raiseAssert e.msg

func getVoluntaryExitsTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicVoluntaryExitsSuffix}"
  except ValueError as e:
    raiseAssert e.msg

func getProposerSlashingsTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicProposerSlashingsSuffix}"
  except ValueError as e:
    raiseAssert e.msg

func getAttesterSlashingsTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicAttesterSlashingsSuffix}"
  except ValueError as e:
    raiseAssert e.msg

func getAggregateAndProofsTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicAggregateAndProofsSuffix}"
  except ValueError as e:
    raiseAssert e.msg

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#broadcast-attestation
func compute_subnet_for_attestation*(
    committees_per_slot: uint64, slot: Slot, committee_index: CommitteeIndex):
    uint64 =
  # Compute the correct subnet for an attestation for Phase 0.
  # Note, this mimics expected Phase 1 behavior where attestations will be
  # mapped to their shard subnet.
  let
    slots_since_epoch_start = slot mod SLOTS_PER_EPOCH
    committees_since_epoch_start =
      committees_per_slot * slots_since_epoch_start

  (committees_since_epoch_start + committee_index.uint64) mod
    ATTESTATION_SUBNET_COUNT

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#broadcast-attestation
func getAttestationTopic*(forkDigest: ForkDigest, subnetIndex: uint64):
    string =
  ## For subscribing and unsubscribing to/from a subnet.
  doAssert subnetIndex < ATTESTATION_SUBNET_COUNT

  try:
    &"/eth2/{$forkDigest}/beacon_attestation_{subnetIndex}/ssz"
  except ValueError as e:
    raiseAssert e.msg

func get_committee_assignments*(
    state: BeaconState, epoch: Epoch,
    validator_indices: HashSet[ValidatorIndex]):
    seq[tuple[subnetIndex: uint8, slot: Slot]] =
  var cache = StateCache()

  let
    committees_per_slot = get_committee_count_per_slot(state, epoch, cache)
    start_slot = compute_start_slot_at_epoch(epoch)

  for slot in start_slot ..< start_slot + SLOTS_PER_EPOCH:
    for index in 0'u64 ..< committees_per_slot:
      let idx = index.CommitteeIndex
      if not disjoint(validator_indices,
          get_beacon_committee(state, slot, idx, cache).toHashSet):
        result.add(
          (compute_subnet_for_attestation(committees_per_slot, slot, idx).uint8,
            slot))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#phase-0-attestation-subnet-stability
proc getStabilitySubnetLength*(): uint64 =
  EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION +
    rand(EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION.int).uint64

proc get_attestation_subnet_changes*(
    state: BeaconState, attachedValidators: openArray[ValidatorIndex],
    prevAttestationSubnets: AttestationSubnets):
    tuple[a: AttestationSubnets, b: set[uint8], c: set[uint8]] =
  static: doAssert ATTESTATION_SUBNET_COUNT == 64  # Fits in a set[uint8]

  # Guaranteed equivalent to wallSlot by cycleAttestationSubnets(), especially
  # since it'll try to run early in epochs, avoiding race conditions.
  let epoch = state.slot.epoch

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#phase-0-attestation-subnet-stability
  var
    attestationSubnets = prevAttestationSubnets
    prevStabilitySubnets: set[uint8] = {}
    stabilitySet: set[uint8] = {}
  for i in 0 ..< attestationSubnets.stabilitySubnets.len:
    static: doAssert ATTESTATION_SUBNET_COUNT <= high(uint8)
    prevStabilitySubnets.incl attestationSubnets.stabilitySubnets[i].subnet

    if epoch >= attestationSubnets.stabilitySubnets[i].expiration:
      attestationSubnets.stabilitySubnets[i].subnet =
        rand(ATTESTATION_SUBNET_COUNT - 1).uint8
      attestationSubnets.stabilitySubnets[i].expiration =
        epoch + getStabilitySubnetLength()

    stabilitySet.incl attestationSubnets.stabilitySubnets[i].subnet

  var nextEpochSubnets: set[uint8]
  for it in get_committee_assignments(
      state, epoch + 1, attachedValidators.toHashSet):
    nextEpochSubnets.incl it.subnetIndex.uint8

  doAssert nextEpochSubnets.len <= attachedValidators.len
  nextEpochSubnets.incl stabilitySet

  let
    epochParity = epoch mod 2
    currentEpochSubnets = attestationSubnets.subscribedSubnets[1 - epochParity]

    expiringSubnets =
      (prevStabilitySubnets +
        attestationSubnets.subscribedSubnets[epochParity]) -
        nextEpochSubnets - currentEpochSubnets - stabilitySet
    newSubnets =
      nextEpochSubnets - (currentEpochSubnets + prevStabilitySubnets)

  doAssert newSubnets.len <= attachedValidators.len + 1
  doAssert (expiringSubnets * currentEpochSubnets).len == 0
  doAssert newSubnets <= nextEpochSubnets

  attestationSubnets.subscribedSubnets[epochParity] = nextEpochSubnets
  (attestationSubnets, expiringSubnets, newSubnets)
