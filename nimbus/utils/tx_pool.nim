# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool
## ================
##
## Current transaction data organisation:
##
## * All incoming transactions are queued (see `tx_queue` module)
## * Transactions indexed/bucketed by *gas price* (see `tx_list` module)
##

import
  std/[algorithm, sequtils],
  ./keequ,
  ./slst,
  ./tx_pool/[tx_item, tx_list, tx_queue, tx_tab],
  eth/[common, keys],
  stew/results

export
  results,
  keequ,
  TxItemRef,
  tx_item.id,
  tx_item.info,
  tx_item.local,
  tx_item.timeStamp,
  tx_item.tx

type
  TxInfo* = enum ##\
    ## Error codes (as used in verification function.)
    txOk = 0

    txVfyByIdQueueList       ## Corrupted ID queue/fifo structure
    txVfyByIdQueueKey        ## Corrupted ID queue/fifo container id
    txVfyByIdQueueSchedule   ## Local flag indicates wrong schedule

    txVfyByGasPriceList      ## Corrupted gas price list structure
    txVfyByGasPriceLeafEmpty ## Empty gas price list leaf record
    txVfyByGasPriceLeafQueue ## Corrupted gas price leaf queue
    txVfyByGasPriceTotal     ## Wrong number of leaves

    txVfyBySenderLeafEmpty   ## Empty sender list leaf record
    txVfyBySenderLeafQueue   ## Corrupted sender leaf queue
    txVfyBySenderTotal       ## Wrong number of leaves

  TxPool* = object of RootObj ##\
    ## Transaction pool descriptor
    byIdQueue: TxQueue       ## Primary table, queued by arrival event
    byGasPrice: TxGasItemLst ## Indexed by gas price
    bySender: TxAddrTab      ## Grouped by sender addresses

const
  TxQueueScheduleReversed =
    toSeq(TxQueueSchedule).reversed

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, other helpers
# ------------------------------------------------------------------------------

proc hash(tx: Transaction): Hash256 {.inline.} =
  ## Transaction hash serves as ID
  tx.rlpHash

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: var TxPool) =
  ## Constructor, returns new tx-pool descriptor.
  xp.byIdQueue.txInit
  xp.byGasPrice.txInit

proc initTxPool*: TxPool =
  ## Ditto
  result.init

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc insert*(xp: var TxPool;
             tx: var Transaction; local = true; info = ""): Result[Hash256,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Add new transaction argument `tx` to the database. If accepted and added
  ## to the database, a `key` value is returned which can be used to retrieve
  ## this transaction direcly via `tx[key].tx`. The following holds for the
  ## returned `key` value (see `[]` below for details):
  ## ::
  ##   xp[key].id == key  # id: transaction key stored in the wrapping container
  ##   tx.toKey == key    # holds as long as tx is not modified
  ##
  ## Adding the transaction will be rejected if the transaction key `tx.toKey`
  ## exists in the database already.
  ##
  ## CAVEAT:
  ##   The returned transaction key `key` for the transaction `tx` is
  ##   recoverable as `tx.toKey` only while the trasaction remains unmodified.
  ##
  let key = tx.hash
  for sched in TxQueueSchedule:
    if xp.byIdQueue.hasKey(key, sched):
      return err()
  let rc = tx.newTxItemRef(key, local, info)
  if rc.isErr:
    return err()
  let item = rc.value
  xp.byIdQueue.txAppend(key, local.toQueueSched, item)
  xp.byGasPrice.txInsert(item.tx.gasPrice, item)
  xp.bySender.txInsert(item.sender, item)
  return ok(key)


proc insert*(xp: var TxPool; tx: Transaction; local = true; info = ""): auto
    {.inline, gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `insert()` for call-by-value transaction
  var ty = tx
  xp.insert(ty,local,info)


proc delete*(xp: var TxPool; key: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  for sched in TxQueueSchedule:
    let rc = xp.byIdQueue.txDelete(key, sched)
    if rc.isOK:
      let item = rc.value
      xp.byGasPrice.txDelete(item.tx.gasPrice, item)
      xp.bySender.txDelete(item.sender, item)
      return ok(item)
  err()

proc delete*(xp: var TxPool; item: TxItemRef): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Variant of `delete()`
  let rc = xp.byIdQueue.txDelete(item.id, item.local.toQueueSched)
  if rc.isOK:
    let item = rc.value
    xp.byGasPrice.txDelete(item.tx.gasPrice, item)
    xp.bySender.txDelete(item.sender, item)
    return ok(item)
  err()

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc len*(xp: var TxPool): int =
  ## Total number of registered transactions
  xp.byIdQueue.nLeaves

proc len*(rq: var TxListItems): int =
  ## Returns the number of items on the argument queue `rq` which is typically
  ## the result of an `SLstRef` type object query holding one or more
  ## duplicates relative to the same index.
  keequ.len(rq)

proc byGasPriceLen*(xp: var TxPool): int =
  ## Number of different gas prices known. For each gas price there is at least
  ## one transaction available.
  xp.byGasPrice.len

proc bySenderLen*(xp: var TxPool): int =
  ## Number of different sendeer adresses known. For each address there is at
  ## least one transaction available.
  xp.bySender.len

# ------------------------------------------------------------------------------
# Public functions, ID queue query
# ------------------------------------------------------------------------------

proc hasKey*(xp: var TxPool; key: Hash256): bool =
  ## Returns `true` if the argument `key` for a transaction exists in the
  ## database, already. If this function returns `true`, then it is save to
  ## use the `xp[key]` paradigm for accessing a transaction container.
  for sched in TxQueueSchedule:
    if xp.byIdQueue.hasKey(key, sched):
      return true

proc toKey*(tx: Transaction): Hash256 {.inline.} =
  ## Retrieves transaction key. Note that the returned argument will only apply
  ## to a transaction in the database if the argument transaction `tx` is
  ## exactly the same as the one passed earlier to the `insert()` function.
  tx.hash

proc `[]`*(xp: var TxPool; key: Hash256): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## If it exists, this function retrieves a transaction container `item`
  ## for the argument `key` with
  ## ::
  ##   item.id == key
  ##
  ## See also commments on `toKey()` and `insert()`.
  ##
  ## Note that the function returns `nil` unless the argument `key` exists
  ## in the database which shiulld be avoided using `hasKey()`.
  for sched in TxQueueSchedule:
    let rc = xp.byIdQueue.eq(key, sched)
    if rc.isOK:
      return rc.value

proc first*(xp: var TxPool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieves the *first* item queued from the `local` queue if it exists,
  ## otherwise from the `remote` queue.
  for sched in TxQueueSchedule:
    let rc = xp.byIdQueue.first(sched)
    if rc.isOK:
      return ok(rc.value.data)
  err()

proc second*(xp: var TxPool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieves the *second* item queued from the `local` queue if it exists,
  ## otherwise from the `remote` queue.
  if xp.len < 2:
    return err()
  if xp.byIdQueue.len(TxLocalQueue) == 1:
    return ok(xp.byIdQueue.first(TxRemoteQueue).value.data)
  # So the local queue has either no or at least two elements
  for sched in TxQueueSchedule:
    let rc = xp.byIdQueue.second(sched)
    if rc.isOK:
      return ok(rc.value.data)
  err()

proc beforeLast*(xp: var TxPool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieves the one before the *last* item queued from the `remote`
  ## queue if it exists, otherwise from the `local` queue.
  if xp.len < 2:
    return err()
  if xp.byIdQueue.len(TxRemoteQueue) == 1:
    return ok(xp.byIdQueue.first(TxLocalQueue).value.data)
  # So the remote queue has either no or at least two elements
  for sched in TxQueueScheduleReversed:
    let rc = xp.byIdQueue.last(sched)
    if rc.isOK:
      return ok(rc.value.data)

proc last*(xp: var TxPool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieves the *last* item queued from the `remote` queue if it exists,
  ## otherwise from the `local` queue.
  for sched in TxQueueScheduleReversed:
    let rc = xp.byIdQueue.last(sched)
    if rc.isOK:
      return ok(rc.value.data)

# ------------------------------------------------------------------------------
# Public functions, gas price query
# ------------------------------------------------------------------------------

proc byGasPriceGe*(xp: var TxPool; gWei: GasInt): Result[TxListItems,void] =
  ## Retrieve the list of transaction records all with the same *least* gas
  ## price *greater or equal* the argument `gWei`. On success, the resulting
  ## list of transactions has at least one item.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  let rc = xp.byGasPrice.ge(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasPriceGt*(xp: var TxPool; gWei: GasInt): Result[TxListItems,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.gt(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasPriceLe*(xp: var TxPool; gWei: GasInt): Result[TxListItems,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.le(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasPriceLt*(xp: var TxPool; gWei: GasInt): Result[TxListItems,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.lt(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasPriceEq*(xp: var TxPool; gWei: GasInt): Result[TxListItems,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.eq(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# Public functions, sender query
# ------------------------------------------------------------------------------

proc bySenderEq*(xp: var TxPool; ethAddr: EthAddress): Result[TxListItems,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `byGasPriceGe()`.
  if xp.bySender.hasKey(ethAddr):
    return ok(xp.bySender[ethAddr])
  err()

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator firstOutItems*(xp: var TxPool): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## ID queue walk/traversal: oldest first (fifo).
  ##
  ## Note: When running in a loop it is ok to delete the current item and
  ## the all items already visited. Items not visited yet must not be deleted.
  for sched in TxQueueSchedule:
    var rc = xp.byIdQueue.first(sched)
    while rc.isOK:
      let (key,data) = (rc.value.key, rc.value.data)
      rc = xp.byIdQueue.next(sched,key)
      yield data

iterator lastInItems*(xp: var TxPool): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## ID queue walk/traversal: newest first (lifo)
  ##
  ## Note: When running in a loop it is ok to delete the current item and
  ## the all items already visited. Items not visited yet must not be deleted.
  for sched in TxQueueScheduleReversed:
    var rc = xp.byIdQueue.last(sched)
    while rc.isOK:
      let (key,data) = (rc.value.key, rc.value.data)
      rc = xp.byIdQueue.prev(sched, key)
      yield data

iterator byGasPriceIncPairs*(xp: var TxPool;
                             fromGe = GasInt.low): (GasInt,var TxListItems) =
  ## Starting at the lowest, this function traverses increasing gas prices.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  ##
  ## Note: When running in a loop it is ok to add or delete any entries,
  ## visited or not visited yet. So, deleting all entries with gas prices
  ## greater or equal than `delMin` would look like:
  ## ::
  ##  for _, txList in xp.byGasPriceIncPairs(fromGe = delMin):
  ##    for tx in txList.nextKeys:
  ##      discard xq.delete(tx)
  ##
  var rc = xp.byGasPrice.ge(fromGe)
  while rc.isOk:
    let yKey = rc.value.key
    yield (ykey, rc.value.data)
    rc = xp.byGasPrice.gt(ykey)

iterator byGasPriceDecPairs*(xp: var TxPool;
                             fromLe = GasInt.high): (GasInt,var TxListItems) =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  ##
  ## Note: When running in a loop it is ok to add or delete any entries,
  ## vistied or not visited yet. So, deleting all entries with gas prices
  ## less or equal than `delMax` would look like:
  ## ::
  ##  for _, txList in xp.byGasPriceDecPairs(fromLe = delMax):
  ##    for tx in txList.nextKeys:
  ##      discard xq.delete(tx)
  ##
  var rc = xp.byGasPrice.le(fromLe)
  while rc.isOk:
    let yKey = rc.value.key
    yield (yKey, rc.value.data)
    rc = xp.byGasPrice.lt(yKey)

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(xp: var TxPool): Result[void,TxInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.
  block:
    let rc = xp.byGasPrice.txVerify
    if rc.isErr:
      case rc.error[0]
      of txListOk:           return err(txOk)
      of txListVfyRbTree:    return err(txVfyByGasPriceList)
      of txListVfyLeafEmpty: return err(txVfyByGasPriceLeafEmpty)
      of txListVfyLeafQueue: return err(txVfyByGasPriceLeafQueue)
      of txListVfySize:      return err(txVfyByGasPriceTotal)
  block:
    let rc = xp.bySender.txVerify
    if rc.isErr:
      case rc.error[0]
      of txTabOk:            return err(txOk)
      of txTabVfyLeafEmpty:  return err(txVfyBySenderLeafEmpty)
      of txTabVfyLeafQueue:  return err(txVfyBySenderLeafQueue)
      of txTabVfySize:       return err(txVfyBySenderTotal)
  block:
    let rc = xp.byIdQueue.txVerify
    if rc.isErr:
      case rc.error[0]
      of txQuOk:             return err(txOk)
      of txQuVfyQueueList:   return err(txVfyByIdQueueList)
      of txQuVfyQueueKey:    return err(txVfyByIdQueueKey)
      of txQuVfySchedule:    return err(txVfyByIdQueueSchedule)

  if xp.len != xp.byIdQueue.nLeaves:
     return err(txVfyByGasPriceTotal)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
