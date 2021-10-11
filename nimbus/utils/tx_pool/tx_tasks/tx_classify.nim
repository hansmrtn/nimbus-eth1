# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Classify Transactions
## ===============================================
##


import
  ../../../db/accounts_cache,
  ../../../forks,
  ../../../transaction,
  ../tx_dbhead,
  ../tx_desc,
  ../tx_item,
  chronicles,
  eth/[common, keys]

type
  TxClassify* = object ##\
    ## Classifier arguments, typically cached values which might
    ## be protected by semaphores
    stageSelect*: set[TxPoolAlgoSelectorFlags] ## Packer strategy symbols

    minFeePrice*: GasPrice   ## Gas price enforced by the pool, `gasFeeCap`
    minTipPrice*: GasPrice   ## Desired tip-per-tx target, `estimatedGasTip`
    minPlGasPrice*: GasPrice ## pre-London minimum gas prioce
    baseFee*: GasPrice       ## Current base fee

    gasLimit*: GasInt        ## Block size limit

logScope:
  topics = "tx-pool classify transaction"

# ------------------------------------------------------------------------------
# Private transaction validation helpers
# ------------------------------------------------------------------------------

proc checkTxBasic(xp: TxPoolRef;
                  item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Rejected transactions will go to the wastebasket
  ##
  if item.tx.txType == TxEip2930 and xp.dbHead.fork < FkBerlin:
    debug "invalid tx: Eip2930 Tx type detected before Berlin"
    return false

  if item.tx.txType == TxEip1559 and xp.dbHead.fork < FkLondon:
    debug "invalid tx: Eip1559 Tx type detected before London"
    return false

  let nonce = ReadOnlyStateDB(xp.dbHead.accDb).getNonce(item.sender)
  if item.tx.nonce < nonce:
    debug "invalid tx: account nonce mismatch",
      txNonce = item.tx.nonce,
      accountNonce = nonce
    return false

  if item.tx.gasLimit < item.tx.intrinsicGas(xp.dbHead.fork):
    debug "invalid tx: not enough gas to perform calculation",
      available = item.tx.gasLimit,
      require = item.tx.intrinsicGas(xp.dbHead.fork)
    return false

  if item.tx.txType != TxLegacy:
    # The total must be the larger of the two
    if item.tx.maxFee < item.tx.maxPriorityFee:
      debug "invalid tx: maxFee is smaller than maPriorityFee",
        maxFee = item.tx.maxFee,
        maxPriorityFee = item.tx.maxPriorityFee
      return false

  true

# ---------------------------

proc checkTxFees(xp: TxPoolRef;
                 item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Rejected transactions will go to the queue(1) waiting for a change
  ## of parameters `gasLimit` and `baseFee`
  ##
  if param.gasLimit < item.tx.gasLimit:
    debug "invalid tx: gasLimit exceeded",
      maxLimit = param.gasLimit,
      gasLimit = item.tx.gasLimit
    return false

  # ensure that the user was willing to at least pay the base fee
  if item.tx.txType != TxLegacy:
    if item.tx.maxFee.GasPriceEx < param.baseFee:
      debug "invalid tx: maxFee is smaller than baseFee",
        maxFee = item.tx.maxFee,
        baseFee = param.baseFee
      return false

  true


proc checkTxBalance(xp: TxPoolRef;
                    item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Function currently unused.
  ##
  let
    balance = ReadOnlyStateDB(xp.dbHead.accDb).getBalance(item.sender)
    gasCost = item.tx.gasLimit.u256 * item.tx.gasPrice.u256
  if balance < gasCost:
    debug "invalid tx: not enough cash for gas",
      available = balance,
      require = gasCost
    return false

  let balanceOffGasCost = balance - gasCost
  if balanceOffGasCost < item.tx.value:
    debug "invalid tx: not enough cash to send",
      available = balance,
      availableMinusGas = balanceOffGasCost,
      require = item.tx.value
    return false

  true

# ---------------------------

proc txLegaAcceptableGasPrice(xp: TxPoolRef;
                              item: TxItemRef; param: TxClassify):
                                bool {.inline.}=
  ## Helper for `classifyTxStaged()`
  if algoStagedPlMinPrice in param.stageSelect:
    if item.tx.gasPrice.GasPriceEx < param.minPlGasPrice:
      return false

  elif algoStaged1559MinTip in param.stageSelect:
    # Fall back transaction selector scheme
    if item.effGasTip < param.minTipPrice:
      return false

  true

proc txAcceptableTipAndFees(xp: TxPoolRef;
                            item: TxItemRef; param: TxClassify):
                              bool {.inline.}=
  ## Helper for `classifyTxStaged()`
  if algoStaged1559MinTip in param.stageSelect:
    if item.effGasTip < param.minTipPrice:
      return false

  if algoStaged1559MinFee in param.stageSelect:
    if item.tx.maxFee.GasPriceEx < param.minFeePrice:
      return false

  true

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------

proc classifyTxValid*(xp: TxPoolRef;
                      item: TxItemRef; param: TxClassify): bool =
  ## Check a (typically new) transaction whether it should be accepted at all
  ## or re-jected right away.
  xp.checkTxBasic(item,param)


proc classifyTxPending*(xp: TxPoolRef;
                        item: TxItemRef; param: TxClassify): bool =
  ## Check whether a valid transaction is ready to be moved to the
  ## `pending` bucket, otherwise it will go to the `queued` bucket.
  if item.tx.estimatedGasTip(param.baseFee) <= 0.GasPriceEx:
    return false

  if not xp.checkTxFees(item,param):
    return false

  #if not item.checkTxBalance(dbHead):
  #  return false

  true


proc classifyTxStaged*(xp: TxPoolRef;
                       item: TxItemRef; param: TxClassify): bool =
  ## Check whether a `pending` transaction is ready to be moved to the
  ## `staged` bucket, otherwise it will go to the `queued` bucket to start
  ## all over.
  if item.tx.txType == TxLegacy:
    xp.txLegaAcceptableGasPrice(item, param)
  else:
    xp.txAcceptableTipAndFees(item, param)

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------