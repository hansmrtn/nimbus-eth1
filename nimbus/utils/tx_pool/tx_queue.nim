# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Queue Structure For Transaction Pool
## ====================================
##
## Ackn: Vaguely inspired by the *txLookup* maps from
## `tx_pool.go <https://github.com/ethereum/go-ethereum/blob/887902ea4d7ee77118ce803e05085bd9055aa46d/core/tx_pool.go#L1646>`_
##

import
  std/[tables],
  ../keequ,
  ./tx_item,
  eth/common,
  stew/results

type
  TxQuInfo* = enum
    txQuOk = 0
    txQuVfyQueueList  ## Corrupted ID queue/fifo structure
    txQuVfyQueueKey   ## Corrupted ID queue/fifo container id
    txQuVfySchedule   ## Local flag indicates wrong schedule

  TxQueueSchedule* = enum ##\
    ## Sub-queues
    TxLocalQueue = 0
    TxRemoteQueue = 1

  TxQueuePair* = ##\
    ## Queue handler wrapper, needed in `first()`, `next()`, etc.
    KeeQuPair[Hash256,TxItemRef]

  TxQueue* = object ##\
    ## Chronological queue and ID table, fifo
    q: array[TxQueueSchedule, KeeQu[Hash256,TxItemRef]]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `not`(sched: TxQueueSchedule): TxQueueSchedule {.inline.} =
  if sched == TxLocalQueue: TxRemoteQueue else: TxLocalQueue

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc toQueueSched*(isLocal: bool): TxQueueSchedule {.inline.} =
  if isLocal: TxLocalQueue else: TxRemoteQueue

proc txInit*(aq: var TxQueue; localSize = 10; remoteSize = 10) =
  aq.q[TxLocalQueue].init(localSize)
  aq.q[TxRemoteQueue].init(remoteSize)

proc txAppend*(aq: var TxQueue;
               key: Hash256; sched: TxQueueSchedule; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reassigning from an existing local/remote queue is supported
  aq.q[sched][key] = item
  aq.q[not sched].del(key)

proc txDelete*(ap: var TxQueue;
               key: Hash256; sched: TxQueueSchedule): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = ap.q[sched].delete(key)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc txVerify*(aq: var TxQueue): Result[void,(TxQuInfo,KeeQuInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  for sched in TxQueueSchedule:
    let rc = aq.q[sched].verify
    if rc.isErr:
      return err((txQuVfyQueueList, rc.error[2]))

  for sched in TxQueueSchedule:
    var rc = aq.q[sched].first
    while rc.isOK:
      let item = rc.value.data
      rc = aq.q[sched].next(rc.value.key)

      # verify key consistency
      if item.id != aq.q[sched].eq(item.id).value.id:
        return err((txQuVfyQueueKey, keeQuOk))

      # verify schedule consistency
      if item.local.toQueueSched != sched:
        return err((txQuVfySchedule, keeQuOk))

  ok()

# ------------------------------------------------------------------------------
# Public fetch & traversal
# ------------------------------------------------------------------------------

proc hasKey*(aq: var TxQueue; key: Hash256; sched: TxQueueSchedule): bool =
  aq.q[sched].hasKey(key)

proc hasKey*(aq: var TxQueue; key: Hash256): bool =
  if aq.q[true.toQueueSched].hasKey(key) or
     aq.q[false.toQueueSched].hasKey(key):
    return true

proc eq*(aq: var TxQueue;
         key: Hash256; sched: TxQueueSchedule): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  if aq.q[sched].hasKey(key):
    return ok(aq.q[sched][key])
  err()

proc first*(aq: var TxQueue; sched: TxQueueSchedule): Result[TxQueuePair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  aq.q[sched].first

proc next*(aq: var TxQueue; sched: TxQueueSchedule; key: Hash256):
         Result[TxQueuePair,void] {.gcsafe,raises: [Defect,KeyError].} =
  aq.q[sched].next(key)

proc prev*(aq: var TxQueue; sched: TxQueueSchedule; key: Hash256):
         Result[TxQueuePair,void] {.gcsafe,raises: [Defect,KeyError].} =
  aq.q[sched].prev(key)

proc last*(aq: var TxQueue; sched: TxQueueSchedule): Result[TxQueuePair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  aq.q[sched].last

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc len*(aq: var TxQueue; sched: TxQueueSchedule): int {.inline.} =
  ## Number of local or remote entries
  aq.q[sched].len

proc nLeaves*(aq: var TxQueue): int {.inline.} =
  aq.q[TxLocalQueue].len + aq.q[TxRemoteQueue].len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------