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
## TODO:
##  * unit tests needed for
##       pending(), ContentFrom()
##

import
  std/[sequtils, tables, times],
  ./keequ,
  ./tx_pool/[tx_tabs, tx_info, tx_item, tx_jobs],
  eth/[common, keys],
  metrics,
  stew/results

export
  TxItemRef,
  TxItemStatus,
  TxJobData,
  TxJobID,
  TxJobKind,
  TxJobPair,
  results,
  tx_item.effectiveGasTip,
  tx_item.gasTipCap,
  tx_item.itemID,
  tx_item.info,
  tx_item.local,
  tx_item.sender,
  tx_item.status,
  tx_item.timeStamp,
  tx_item.tx

const
  TxNoBaseFee* = ##\
    ## Initialising this value will cause the `baseFee` be disabled in the
    ## priced list(s).
    GasInt.low

  txPoolLifeTime = initDuration(hours = 3)
  txPriceLimit = 1

  # Journal:   "transactions.rlp",
  # Rejournal: time.Hour,
  #
  # PriceBump:  10,
  #
  # AccountSlots: 16,
  # GlobalSlots:  4096 + 1024, // urgent + floating queue capacity with
  #                            // 4:1 ratio
  # AccountQueue: 64,
  # GlobalQueue:  1024,

type
  TxPoolError* = enum
    txPoolErrNone = ##\
      ## Default/reset value
      (0, "no error")

    txPoolErrUnspecified = ##\
      ## Some unspecified error occured
      "generic error"

    txPoolErrAlreadyKnown = ##\
      ## The transactions is already contained within the pool
      "already known"

    txPoolErrInvalidSender = ##\
      ## The transaction contains an invalid signature.
      "invalid sender"

    txPoolErrUnderpriced = ##\
      ## A transaction's gas price is below the minimum configured for the
      ## transaction pool.
      "transaction underpriced"

    txPoolErrTxPoolOverflow = ##\
      ## The transaction pool is full and can't accpet another remote
      ## transaction.
      "txpool is full"

    txPoolErrReplaceUnderpriced = ##\
      ## A transaction is attempted to be replaced with a different one
      ## without the required price bump.
      "replacement transaction underpriced"

    txPoolErrGasLimit = ##\
      ## A transaction's requested gas limit exceeds the maximum allowance
      ## of the current block.
      "exceeds block gas limit"

    txPoolErrNegativeValue = ##\
      ## A sanity error to ensure no one is able to specify a transaction
      ## with a negative value.
      "negative value"

    txPoolErrOversizedData = ##\
      ## The input data of a transaction is greater than some meaningful
      ## limit a user might use. This is not a consensus error making the
      ## transaction invalid, rather a DOS protection.
      "oversized data"


  TxPool* = object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time     ## Start date (read-only)
    gasPrice*: GasInt
    lifeTime*: Duration ## Maximum amount of time non-executable
    byJobs: TxJobs      ## Jobs batch list
    txDB: TxTabsRef     ## Transaction lists & tables

{.push raises: [Defect].}

declareGauge invalid_transactions, "Number of invalid transactions"
declareGauge valid_transactions, "Number of valid transactions"
declareGauge known_transactions, "Number of known transactions"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc utcNow: Time =
  now().utc.toTime

proc pp(t: Time): string =
  t.format("yyyy-MM-dd'T'HH:mm:ss'.'fff", utc())

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

#proc knownTxMeterMark(xp: var TxPool; n = 1) = discard # TODO
#proc invalidTxMeterMark(xp: var TxPool; n = 1) = discard # TODO
#proc validTxMeterMark(xp: var TxPool; n = 1) = discard # TODO

# ------------------------------------------------------------------------------
# Private run handlers
# ------------------------------------------------------------------------------

# core/tx_pool.go(384): for addr := range pool.queue {
proc inactiveJobsEviction(xp: var TxPool; maxLifeTime: Duration)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Any non-local transaction old enough will be removed
  let deadLine = utcNow() - maxLifeTime
  var rc = xp.txDB.byItemID.eq(local = false).first
  while rc.isOK:
    let item = rc.value.data
    if deadLine < item.timeStamp:
      break
    rc = xp.txDB.byItemID.eq(local = false).next(item.itemID)
    discard xp.txDB.delete(item.itemID)


# core/tx_pool.go(889): func (pool *TxPool) addTxs(txs []*types.Transaction, ..
proc addTxs(xp: var TxPool; txs: var openArray[Transaction];
            local: bool; status: TxItemStatus; info = ""):
              Result[void,seq[TxPoolError]]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Attempts to queue a batch of transactions if they are valid.
  var
    nErrors = 0
    errList = newSeq[TxPoolError](txs.len)

  # Filter out known ones without obtaining the pool lock or recovering
  # signatures
  for i in 0 ..< txs.len:
    var tx = txs[i]

    # If the transaction is known, pre-set the error slot
    let rc = xp.txDB.insert(tx, local, status, info)
    if rc.isErr:
      case rc.error:
      of txTabsErrAlreadyKnown:
        inc known_transactions
        errList[i] = txPoolErrAlreadyKnown
      of txTabsErrInvalidSender:
        inc invalid_transactions
        errList[i] = txPoolErrInvalidSender
      else:
        errList[i] = txPoolErrUnspecified
      nErrors.inc
      continue

    inc valid_transactions

  if 0 < nErrors:
    return err(errList)
  ok()


proc addTxs(xp: var TxPool; tx: var Transaction;
            local: bool; status: TxItemStatus; info = ""):
           Result[void,TxPoolError]
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Convenience wrapper
  var txs = [tx]
  let rc = xp.addTxs(txs, local, status, info)
  if rc.isErr:
    return err(rc.error[0])
  ok()

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: var TxPool; baseFee = TxNoBaseFee) =
  ## Constructor, returns new tx-pool descriptor.
  xp.txDB = init(type TxTabsRef, baseFee)
  xp.startDate = utcNow()
  xp.gasPrice = txPriceLimit
  xp.lifeTime = txPoolLifeTime

proc init*(T: type TxPool; baseFee = TxNoBaseFee): T =
  ## Ditto
  result.init(baseFee)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc startDate*(xp: var TxPool): Time {.inline.} =
  ## Getter
  xp.startDate

proc baseFee*(xp: var TxPool): GasInt {.inline.} =
  ## Getter, the `baseFee` implying the price list valuation and order. If
  ## this entry in disabled, the value `TxNoBaseFee` is returnded.
  xp.txDB.baseFee

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `baseFee=`*(xp: var TxPool; val: GasInt)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Setter, new base fee (implies reorg). The argument value `TxNoBaseFee`
  ## disables the `baseFee`.
  xp.txDB.baseFee = val

# ------------------------------------------------------------------------------
# GO tx_pool todo list
# ------------------------------------------------------------------------------

# ErrAlreadyKnown is returned if the transactions is already contained
# within the pool.
#ErrAlreadyKnown = errors.New("already known")

# ErrInvalidSender is returned if the transaction contains an invalid signature.
#ErrInvalidSender = errors.New("invalid sender")

# ErrUnderpriced is returned if a transaction's gas price is below the minimum
# configured for the transaction pool.
#ErrUnderpriced = errors.New("transaction underpriced")

# ErrTxPoolOverflow is returned if the transaction pool is full and can't accpet
# another remote transaction.
#ErrTxPoolOverflow = errors.New("txpool is full")

# ErrReplaceUnderpriced is returned if a transaction is attempted to be replaced
# with a different one without the required price bump.
#ErrReplaceUnderpriced = errors.New("replacement transaction underpriced")

# ErrGasLimit is returned if a transaction's requested gas limit exceeds the
# maximum allowance of the current block.
#ErrGasLimit = errors.New("exceeds block gas limit")

# ErrNegativeValue is a sanity error to ensure no one is able to specify a
# transaction with a negative value.
#ErrNegativeValue = errors.New("negative value")

# ErrOversizedData is returned if the input data of a transaction is greater
# than some meaningful limit a user might use. This is not a consensus error
# making the transaction invalid, rather a DOS protection.
#ErrOversizedData = errors.New("oversized data")

# TxStatus is the current status of a transaction as seen by the pool.
#type TxStatus uint

#const (
#       TxStatusUnknown TxStatus = iota
#       TxStatusQueued
#       TxStatusPending
#       TxStatusIncluded)

# TxPoolConfig are the configuration parameters of the transaction pool.
#type TxPoolConfig struct {
#   Locals    []common.Address // Addresses that should be treated by default
#                              // as local
#   NoLocals  bool             // Whether local transaction handling should be
#                              // disabled
#   Journal   string           // Journal of local transactions to survive node
#                              // restarts
#   Rejournal time.Duration    // Time interval to regenerate the local
#                              // transaction journal
#
#   PriceLimit uint64   // Minimum gas price to enforce for acceptance into the
#                       // pool
#   PriceBump  uint64   // Minimum price bump percentage to replace an already
#                       // existing transaction (nonce)
#
#   AccountSlots uint64 // Number of executable transaction slots guaranteed
#                       // per account
#   GlobalSlots  uint64 // Maximum number of executable transaction slots for
#                       // all accounts
#   AccountQueue uint64 // Maximum number of non-executable transaction slots
#                       // permitted per account
#   GlobalQueue  uint64 // Maximum number of non-executable transaction slots
#                       // for all accounts
#
#   Lifetime time.Duration) // Maximum amount of time non-executable
#                           // transaction are queued

# DefaultTxPoolConfig contains the default configurations for the transaction
# pool.

# sanitize checks the provided user configurations and changes anything that's
# unreasonable or unworkable.
#func (config *TxPoolConfig) sanitize() TxPoolConfig

# TxPool contains all currently known transactions. Transactions
# enter the pool when they are received from the network or submitted
# locally. They exit the pool when they are included in the blockchain.
#
# The pool separates processable transactions (which can be applied to the
# current state) and future transactions. Transactions move between those
# two states over time as they are received and processed.
#type TxPool struct

# NewTxPool creates a new transaction pool to gather, sort and filter inbound
# transactions from the network.
#func NewTxPool(
#  config TxPoolConfig, chainconfig *params.ChainConfig, chain blockChain)
#    *TxPool

# Stop terminates the transaction pool.
#func (pool *TxPool) Stop()

# SubscribeNewTxsEvent registers a subscription of NewTxsEvent and
# starts sending event to the given channel.
#func (pool *TxPool) SubscribeNewTxsEvent(ch chan<- NewTxsEvent)
#  event.Subscription

# GasPrice returns the current gas price enforced by the transaction pool.
#func (pool *TxPool) GasPrice() *big.Int

# SetGasPrice updates the minimum price required by the transaction pool for a
# new transaction, and drops all transactions below this threshold.
#func (pool *TxPool) SetGasPrice(price *big.Int)

# Nonce returns the next nonce of an account, with all transactions executable
# by the pool already applied on top.
#func (pool *TxPool) Nonce(addr common.Address) uint64

# Stats retrieves the current pool stats, namely the number of pending and the
# number of queued (non-executable) transactions.
#func (pool *TxPool) Stats() (int, int)

# Content retrieves the data content of the transaction pool, returning all the
# pending as well as queued transactions, grouped by account and sorted by
# nonce.
#func (pool *TxPool) Content()
#  (map[common.Address]types.Transactions,
#   map[common.Address]types.Transactions)

# ------------------------------------------------------------------------------
# Public functions, go like API -- TxPool
# ------------------------------------------------------------------------------

# -- // This is like AddRemotes, but waits for pool reorganization. Tests use
# -- // this method.
# -- func (pool *TxPool) AddRemotesSync(txs []*types.Transaction) []error

# core/tx_pool.go(514): func (pool *TxPool) ContentFrom(addr common.Address) ..
proc ContentFrom*(xp: var TxPool;
                  sender: EthAddress): (seq[TxItemRef],seq[TxItemRef])
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieves the data content of the transaction pool, returning the
  ## pending as well as queued transactions of this address, grouped by
  ## nonce.
  let rcSched = xp.txDB.bySender.eq(sender)
  if rcSched.isOK:
    let rcPending = rcSched.eq(txItemPending)
    if rcPending.isOK:
      for itemList in rcPending.value.data.walkItemList:
        result[0].add toSeq(itemList.walkItems)
    let rcQueued = rcSched.eq(txItemQueued)
    if rcQueued.isOK:
      for itemList in rcQueued.value.data.walkItemList:
        result[1].add toSeq(itemList.walkItems)


# core/tx_pool.go(536): func (pool *TxPool) Pending(enforceTips bool) (map[..
proc pending*(xp: var TxPool; enforceTips = false): seq[seq[TxItemRef]]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## The function retrieves all currently processable transaction items,
  ## grouped by origin account and sorted by nonce. The returned transaction
  ## items are copies and can be freely modified.
  ##
  ## The `enforceTips` parameter can be used to do an extra filtering on the
  ## pending transactions and only return those whose **effective** tip is
  ## large enough in the next pending execution environment.
  for schedList in xp.txDB.bySender.walkSchedList:
    var list: seq[TxItemRef]
    for itemList in schedList.walkItemList(txSenderPending):
      for item in itemList.walkItems:
        if item.local or
           not enforceTips or
           xp.gasPrice <= item.effectiveGasTip:
          list.add item.dup
    if 0 < list.len:
      result.add list

# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc locals*(xp: var TxPool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered local by the pool.
  toSeq(xp.txDB.bySender
               .walkNonceList(local = true))
               .mapIt(it.ge(AccountNonce.low).first.value.sender)

# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
proc addLocals*(xp: var TxPool; txs: var openArray[Transaction];
                status = txItemQueued; info = ""):
              Result[void,seq[TxPoolError]]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueues a batch of transactions into the pool if they are valid,
  ## marking the senders as local ones, ensuring they go around the local
  ## pricing constraints.
  ##
  ## This method is used to add transactions from the RPC API and performs
  ## synchronous pool reorganization and event propagation.
  xp.addTxs(txs, local = true, status, info)

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
proc addLocal*(xp: var TxPool; tx: var Transaction;
               status = txItemQueued; info = ""):
             Result[void,TxPoolError]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## AddLocal enqueues a single local transaction into the pool if it is valid.
  ## This is a convenience wrapper aroundd AddLocals.
  xp.addTxs(tx, local = true, status, info)

# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc addRemotes*(xp: var TxPool; txs: var openArray[Transaction];
                 status = txItemQueued; info = ""):
                  Result[void,seq[TxPoolError]]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueue a batch of transactions into the pool if they are valid. If
  ## the senders are not among the locally tracked ones, full pricing
  ## constraints will apply.
  ##
  ## This method is used to add transactions from the p2p network and does not
  ## wait for pool reorganization and internal event propagation.
  xp.addTxs(txs, local = false, status, info)

# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc addRemote*(xp: var TxPool; tx: var Transaction;
                status = txItemQueued; info = ""):
              Result[void,TxPoolError]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Enqueues a single transaction into the pool if it is valid.
  ## This is a convenience wrapper around AddRemotes.
  ##
  ## Deprecated: use AddRemotes
  xp.addTxs(tx, local = false, status, info)

# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
proc has*(xp: var TxPool; hash: Hash256): bool =
  ## Indicator whether `TxPool` has a transaction cached with the given hash.
  xp.txDB.byItemID.hasKey(hash)

# core/tx_pool.go(975): func (pool *TxPool) Status(hashes []common.Hash) ..
proc status*(xp: var TxPool; hashes: openArray[Hash256]): seq[TxItemStatus]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns the status (unknown/pending/queued) of a batch of transactions
  ## identified by their hashes.
  result.setLen(hashes.len)
  for n in 0 ..< hashes.len:
    let rc = xp.txDB.byItemID.eq(hashes[n])
    if rc.isOK:
      result[n] = rc.value.status

# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
proc get*(xp: var TxPool; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns a transaction if it is contained in the pool.
  xp.txDB.byItemID.eq(hash)

# ------------------------------------------------------------------------------
# Public functions, go like API -- accountSet
# ------------------------------------------------------------------------------

# accountSet is simply a set of addresses to check for existence, and a signer
# capable of deriving addresses from transactions.

# ------------------------------------------------------------------------------
# Public functions, go like API -- addressByHeartbeat
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public functions, go like API -- lookup
# ------------------------------------------------------------------------------

# -- // Get returns a transaction if it exists in the lookup, or nil if not
# -- // found.
# -- func (t *txLookup) Get(hash common.Hash) *types.Transaction {
#
# -- // Slots returns the current number of slots used in the lookup.
# -- func (t *txLookup) Slots() int
#
# -- // Add adds a transaction to the lookup.
# -- func (t *txLookup) Add(tx *types.Transaction, local bool)
#
# -- // Remove removes a transaction from the lookup.
# -- func (t *txLookup) Remove(hash common.Hash)

# core/tx_pool.go(1681): func (t *txLookup) Range(f func(hash common.Hash, ..
iterator rangeFifo*(xp: var TxPool; local: varargs[bool]): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Local/remote transaction queue walk/traversal: oldest first
  ##
  ## :Note:
  ##    When running in a loop it is ok to delete the current item and all
  ##    the items already visited. Items not visited yet must not be deleted.
  for isLocal in local:
    var rc = xp.txDB.byItemID.eq(isLocal).first
    while rc.isOK:
      let item = rc.value.data
      rc = xp.txDB.byItemID.eq(isLocal).next(item.itemID)
      yield item

iterator rangeLifo*(xp: var TxPool; local: varargs[bool]): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Local or remote transaction queue walk/traversal: oldest last
  ##
  ## See also the **Note* at the comment for `rangeFifo()`.
  for isLocal in local:
    var rc = xp.txDB.byItemID.eq(isLocal).last
    while rc.isOK:
      let item = rc.value.data
      rc = xp.txDB.byItemID.eq(isLocal).prev(item.itemID)
      yield item

# core/tx_pool.go(1713): func (t *txLookup) GetLocal(hash common.Hash) ..
proc getLocal*(xp: var TxPool; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns a local transaction if it exists.
  xp.txDB.byItemID.eq(local = true).eq(hash)

# core/tx_pool.go(1721): func (t *txLookup) GetRemote(hash common.Hash) ..
proc getRemote*(xp: var TxPool; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns a remote transaction if it exists.
  xp.txDB.byItemID.eq(local = false).eq(hash)

# core/tx_pool.go(1728): func (t *txLookup) Count() int {
proc count*(xp: var TxPool): int {.inline.} =
  ## The current number of transactions
  xp.txDB.byItemID.nItems

# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
proc localCount*(xp: var TxPool): int {.gcsafe,raises: [Defect,KeyError].} =
  ## The current number of local transactions
  xp.txDB.byItemID.eq(local = true).nItems

# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
proc remoteCount*(xp: var TxPool): int {.gcsafe,raises: [Defect,KeyError].} =
  ## The current number of remote transactions
  xp.txDB.byItemID.eq(local = false).nItems

# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc remoteToLocals*(xp: var TxPool; signer: EthAddress): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  let rc = xp.txDB.bySender.eq(signer).eq(local = false)
  if rc.isOK:
    let nRemotes = xp.remoteCount
    for itemList in rc.value.data.walkItemList:
      for item in itemList.walkItems:
        discard xp.txDB.reassign(item, local = true)
    return nRemotes - xp.remoteCount

# core/tx_pool.go(1813): func (t *txLookup) RemotesBelowTip(threshold ..
proc remotesBelowTip*(xp: var TxPool; threshold: GasInt): seq[Hash256]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Finds all remote transactions below the given tip threshold (effective
  ## only with *EIP-1559* support, otherwise all transactions are returned.)
  for itemList in xp.txDB.byTipCap.decItemList(maxCap = threshold):
    for item in itemList.walkItems:
      if not item.local:
        result.add item.itemID

# ------------------------------------------------------------------------------
# Public functions, other
# ------------------------------------------------------------------------------

proc commit*(xp: var TxPool): int {.gcsafe,raises: [Defect,KeyError].} =
  ## Executes the jobs in the queue (if any.) The function returns the
  ## number of executes jobs.
  var rc = xp.byJobs.shift
  while rc.isOK:
    let jobKvp = rc.value
    rc = xp.byJobs.shift

    var header: BlockHeader
    case jobKvp.data.kind
    of txJobNone:
      echo "here"
    of txJobsInactiveJobsEviction:
      xp.inactiveJobsEviction(xp.lifeTime)
      result.inc
    else:
      discard

proc isJobOk*(id: TxJobID): bool =
  ## The function returns `true` if the argument job `id` is valid.
  id != 0.TxJobID and id <= TxJobIdMax

proc job*(xp: var TxPool; job: TxJobData): TxJobID
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Append a new job to the queue.
  xp.byJobs.add(job)

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc txDB*(xp: var TxPool): TxTabsRef {.inline.} =
  ## Getter, Transaction lists & tables (for debugging only)
  xp.txDB

proc verify*(xp: var TxPool): Result[void,TxVfyError]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.

  block:
    let rc = xp.byJobs.verify
    if rc.isErr:
      return rc

  xp.txDB.verify

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
