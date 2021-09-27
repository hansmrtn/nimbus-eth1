# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[algorithm, os, random, sequtils, strformat, strutils, times],
  ../nimbus/config,
  ../nimbus/db/db_chain,
  ../nimbus/p2p/chain,
  ../nimbus/utils/tx_pool,
  ../nimbus/utils/tx_pool/tx_perjobapi,
  ./test_txpool/[block_chain, helpers],
  eth/[common, keys],
  stint,
  unittest2

const
  prngSeed = 42
  baseDir = "tests"
  mainnetCapture = "test_txpool" / "mainnet50688.txt.gz"
  loadFile = mainnetCapture

  # 75% <= #local/#remote <= 1/75%
  # note: by law of big numbers, the ratio will exceed any upper or lower
  #       on a +1/-1 random walk if running long enough (with expectation
  #       value 0)
  randInitRatioBandPC = 75

  # 95% <= #remote-deleted/#remote-present <= 1/95%
  deletedItemsRatioBandPC = 95

  # 70% <= #addr-local/#addr-remote <= 1/70%
  # note: this ratio might vary due to timing race conditions
  addrGroupLocalRemotePC = 70

  # test block chain
  networkId = MainNet

var
  prng = prngSeed.initRand

  # to be set up in runTxLoader()
  okCount: array[bool,int]             # entries: [local,remote] entries
  statCount: array[TxItemStatus,int] # ditto

  txList: seq[TxItemRef]
  effGasTips: seq[GasInt]
  gasTipCaps: seq[GasInt]

  # running block chain
  bcDB: BaseChainDB

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc randOkRatio: int =
  if okCount[false] == 0:
    int.high
  else:
    (okCount[true] * 100 / okCount[false]).int

proc randStatusRatios: seq[int] =
  for n in 1 .. statCount.len:
    let
      inx = (n mod statCount.len).TxItemStatus
      prv = (n - 1).TxItemStatus
    if statCount[inx] == 0:
      result.add int.high
    else:
      result.add (statCount[prv] * 100 / statCount[inx]).int

proc randOk: bool =
  result = prng.rand(1) > 0
  okCount[result].inc

proc randStatus: TxItemStatus =
  result = prng.rand(TxItemStatus.high.ord).TxItemStatus
  statCount[result].inc


proc slurpItems(xp: var TxPool): seq[TxItemRef] =
  var rList: seq[TxItemRef]
  let appItFn = proc(item: TxItemRef): bool =
                  rList.add item
                  true
  xp.itemsApply(appItFn, local = true)
  xp.itemsApply(appItFn, local = false)
  result = rList


proc importTxPool(xp: var TxPool; noisy: bool;
                  file: string; loadBlocks: int; loadTxs: int) =
  var
    txCount = 0
    chainNo = 0
    chainDB = bcDB.newChain

  # clear waste basket
  discard xp.flushRejects

  for chain in file.undumpNextGroup:
    chainNo.inc
    if chain[0][0].blockNumber == 0.u256:
      # Verify Genesis
      doAssert chain[0][0] == chainDB.db.getBlockHeader(0.u256)

    elif chain[0][0].blockNumber < loadBlocks.u256:
      let (headers,bodies) = (chain[0],chain[1])
      doAssert chainDB.persistBlocks(headers,bodies) == ValidationResult.OK

    else:
      for chainInx in 0 ..< chain[0].len:
        # load transactions, one-by-one
        let
          blkNum = chain[0][chainInx].blockNumber
          txs = chain[1][chainInx].transactions
        for n in 0 ..< txs.len:
          txCount.inc
          let
            local = randOK()
            status = randStatus()
            localInfo = if local: "L" else: "R"
            info = &"{txCount} #{blkNum}({chainNo}) {n}/{txs.len} {localInfo}"
          noisy.showElapsed(&"insert: local={local} {info}"):
            var tx = txs[n]
            xp.addTx(tx, local, status, info)
          if loadTxs <= txCount:
            # make sure that the waste basket was empty
            doAssert xp.flushRejects[0] == 0
            return


proc toTxPool(q: var seq[TxItemRef]; baseFee: GasInt;
              noisy = true; maxRejects = txTabMaxRejects): TxPool =
  result.init(bcDB, baseFee)
  result.setMaxRejects(maxRejects)
  noisy.showElapsed(&"Loading {q.len} transactions"):
    for w in q:
      var tx = w.tx
      result.addTx(tx, w.local, w.status, w.info)
  doAssert result.count.total == q.len
  doAssert result.flushRejects[0] == 0


proc toTxPool(q: var seq[TxItemRef]; baseFee: GasInt; noisy = true;
              timeGap: var Time; nRemoteGapItems: var int;
              remoteItemsPC = 30; delayMSecs = 200): TxPool =
  ## Variant of `toTxPool()` where the loader sleeps some time after
  ## `remoteItemsPC` percent loading remote items.
  doAssert 0 < remoteItemsPC and remoteItemsPC < 100
  result.init(bcDB, baseFee)
  var
    delayAt = okCount[false] * remoteItemsPC div 100
    middleOfTimeGap = initDuration(milliSeconds = delayMSecs div 2)
    remoteCount = 0
  noisy.showElapsed(&"Loading {q.len} transactions"):
    for w in q:
      var tx = w.tx
      result.addTx(tx, w.local, w.status, w.info)
      if not w.local and remoteCount < delayAt:
        remoteCount.inc
        if delayAt == remoteCount:
          nRemoteGapItems = remoteCount
          noisy.say &"time gap after {remoteCount} remote transactions"
          timeGap = result.get(w.itemID).value.timeStamp + middleOfTimeGap
          delayMSecs.sleep
  doAssert result.count.total == q.len
  doAssert result.flushRejects[0] == 0


proc addOrFlushGroupwise(xp: var TxPool;
                         grpLen: int; seen: var seq[TxItemRef]; w: TxItemRef;
                         noisy = true): bool =
  # to be run as call back inside `itemsApply()`
  try:
    seen.add w
    if grpLen <= seen.len:
      # clear waste basket
      discard xp.txDB.flushRejects

      # flush group-wise
      let xpLen = xp.txDB.statsCount.total
      noisy.say "*** updateSeen: deleting ", seen.mapIt($it.itemID).join(" ")
      for item in seen:
        doAssert xp.txDB.reject(item,txInfoErrUnspecified)
      doAssert xpLen == seen.len + xp.txDB.statsCount.total
      doAssert seen.len == xp.txDB.statsCount.rejected
      seen.setLen(0)

      # clear waste basket
      discard xp.txDB.flushRejects

    return true

  except CatchableError:
    raiseAssert "addOrFlushGroupwise() has problems: " &
      getCurrentExceptionMsg()

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runTxLoader(noisy = true;
                 baseFee: GasInt;
                 dir = baseDir; captureFile = loadFile,
                 numBlocks = 0; numTransactions = 0) =
  let
    elapNoisy = noisy
    veryNoisy = false # noisy
    loadBlocks = if numBlocks == 0: 30000 else: numBlocks
    loadTxs = if numTransactions == 0: 900 else: numTransactions
    name = captureFile.splitFile.name.split(".")[0]
    baseInfo = if baseFee != TxNoBaseFee: &" with baseFee={baseFee}" else: ""

  # Reset/initialise
  okCount.reset
  statCount.reset
  txList.reset
  effGasTips.reset
  gasTipCaps.reset
  bcDB = networkId.blockChainForTesting

  suite &"TxPool: Transactions from {name} capture{baseInfo}":
    var xp = init(type TxPool, bcDB, baseFee)
    check txList.len == 0
    check xp.txDB.verify.isOK

    test &"Import at least {loadBlocks.toKMG} blocks "&
        &"and collect {loadTxs} transactions":
      elapNoisy.showElapsed("Total collection time"):
        xp.importTxPool(veryNoisy, dir / captureFile,
                        loadBlocks = loadBlocks, loadTxs = loadTxs)

      # make sure that the block chain was initialised
      check loadBlocks.u256 <= bcDB.getCanonicalHead.blockNumber

      check xp.count.total == foldl(okCount.toSeq, a+b)   # add okCount[] values
      check xp.count.total == foldl(statCount.toSeq, a+b) # ditto statCount[]

      # make sure that PRNG did not go bonkers
      let localRemoteRatio = randOkRatio()
      check randInitRatioBandPC < localRemoteRatio
      check localRemoteRatio < (10000 div randInitRatioBandPC)

      for statusRatio in randStatusRatios():
        check randInitRatioBandPC < statusRatio
        check statusRatio < (10000 div randInitRatioBandPC)

      # Note: expecting enough transactions in the `goerliCapture` file
      check xp.count.total == loadTxs
      check xp.verify.isOk

      # Load txList[]
      txList = xp.slurpItems
      check txList.len == xp.count.total

    test "Load gas prices and priority fees":

      elapNoisy.showElapsed("Load gas prices"):
        for nonceList in xp.txDB.byGasTip.incNonceList:
          effGasTips.add nonceList.ge(AccountNonce.low)
                                  .first.value.effectiveGasTip

      check effGasTips.len == xp.txDB.byGasTip.len

      elapNoisy.showElapsed("Load priority fee caps"):
        for itemList in xp.txDB.byTipCap.incItemList:
          gasTipCaps.add itemList.first.value.tx.gasTipCap
      check gasTipCaps.len == xp.txDB.byTipCap.len


proc runTxBaseTests(noisy = true; baseFee: GasInt) =

  let
    elapNoisy = false
    baseInfo = if baseFee != TxNoBaseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Play with queues and lists{baseInfo}":

    var xq = txList.toTxPool(baseFee, noisy)
    let
      nLocal = xq.count.local
      nRemote = xq.count.remote
      txList0local = txList[0].local

    test &"Swap local/remote ({nLocal}/{nRemote}) queues":
      check nLocal + nRemote == txList.len

      # Start with local queue
      for w in [(true, 0, nLocal), (false, nLocal, txList.len)]:
        let local = w[0]
        for n in w[1] ..< w[2]:
          check txList[n].local == local
          check xq.txDB.reassign(txList[n], not local)
          check txList[n].info == xq.txDB.byItemID.eq(not local)
                                                  .last.value.data.info
          check xq.txDB.verify.isOK
      check nLocal == xq.count.remote
      check nRemote == xq.count.local

      # maks sure the list item was left unchanged
      check txList0local == txList[0].local

      # Verify sorting of swapped queue
      var count, n: int

      count = 0
      for (local, start) in [(true, nLocal), (false, 0)]:
        var rc = xq.txDB.byItemID.eq(local).first
        n = start
        while rc.isOK and n < txList.len:
          check txList[n].info == rc.value.data.info
          rc = xq.txDB.byItemID.eq(local).next(rc.value.data.itemID)
          n.inc
          count.inc
      check count == txList.len
      check n == nLocal

      # And reverse
      count = 0
      for (local, top) in [(false, nLocal), (true, txList.len)]:
        var rc = xq.txDB.byItemID.eq(local).last
        n = top
        while rc.isOK and 0 < n:
          n.dec
          check txList[n].info == rc.value.data.info
          rc = xq.txDB.byItemID.eq(local).prev(rc.value.data.itemID)
          count.inc
      check count == txList.len
      check n == nLocal

    # ---------------------------------

    block:
      var xq = txList.toTxPool(baseFee, noisy)
      let
        veryNoisy = noisy # and false
        indent = " ".repeat(6)

      test &"Walk {xq.txDB.byGasTip.len} gas prices "&
          &"for {txList.len} transactions":
        block:
          var
            txCount = 0
            gpList: seq[GasInt]

          elapNoisy.showElapsed("Increasing gas price transactions walk"):
            for nonceList in xq.txDB.byGasTip.incNonceList:
              var
                infoList: seq[string]
                gasTxCount = 0
              for itemList in nonceList.incItemList:
                for item in itemList.walkItems:
                  infoList.add item.info
                gasTxCount += itemList.nItems

              check gasTxCount == nonceList.nItems
              txCount += gasTxCount

              let gasTip = nonceList.ge(AccountNonce.low)
                                    .first.value.effectiveGasTip
              gpList.add gasTip
              veryNoisy.say &"gasTip={gasTip} for {infoList.len} entries:"
              veryNoisy.say indent, infoList.join(&"\n{indent}")

          check txCount == xq.count.total
          check gpList.len == xq.txDB.byGasTip.len
          check effGasTips.len == gpList.len
          check effGasTips == gpList

        block:
          var
            txCount = 0
            gpList: seq[GasInt]

          elapNoisy.showElapsed("Decreasing gas price transactions walk"):
            for nonceList in xq.txDB.byGasTip.decNonceList:
              var
                infoList: seq[string]
                gasTxCount = 0
              for itemList in nonceList.decItemList:
                for item in itemList.walkItems:
                  infoList.add item.info
                gasTxCount += itemList.nItems

              check gasTxCount == nonceList.nItems
              txCount += gasTxCount

              let gasTip = nonceList.ge(AccountNonce.low)
                                    .first.value.effectiveGasTip
              gpList.add gasTip
              veryNoisy.say &"gasPrice={gasTip} for {infoList.len} entries:"
              veryNoisy.say indent, infoList.join(&"\n{indent}")

          check txCount == xq.count.total
          check gpList.len == xq.txDB.byGasTip.len
          check effGasTips.len == gpList.len
          check effGasTips == gpList.reversed

    # ---------------------------------

    block:
      const groupLen = 13
      let veryNoisy = noisy and false

      test &"Load/forward walk ID queue, " &
          &"deleting groups of at most {groupLen}":
        var
          xq = txList.toTxPool(baseFee, noisy)
          seen: seq[TxItemRef]
        let
          itFn = proc(item: TxItemRef): bool =
                   xq.addOrFlushGroupwise(groupLen, seen, item, veryNoisy)
        check xq.txDB.verify.isOK
        elapNoisy.showElapsed("Forward delete-walk ID queue"):
          xq.itemsApply(itFn, local = true)
          xq.itemsApply(itFn, local = false)
        check xq.txDB.verify.isOK
        check seen.len == xq.count.total
        check seen.len < groupLen

      test &"Load/reverse walk ID queue, " &
          &"deleting in groups of at most {groupLen}":
        var
          xq = txList.toTxPool(baseFee, noisy)
          seen: seq[TxItemRef]
        let
          itFn = proc(item: TxItemRef): bool =
                   xq.addOrFlushGroupwise(groupLen, seen, item, veryNoisy)
        check xq.txDB.verify.isOK
        elapNoisy.showElapsed("Revese delete-walk ID queue"):
          xq.itemsApply(itFn, local = true)
          xq.itemsApply(itFn, local = false)
        check xq.txDB.verify.isOK
        check seen.len == xq.count.total
        check seen.len < groupLen

    # ---------------------------------

    block:
      var
        xq = txList.toTxPool(baseFee = baseFee,
                             maxRejects = txList.len,
                             noisy = noisy)
        count = 0
      let
        delLe = effGasTips[0] + ((effGasTips[^1] - effGasTips[0]) div 3)
        delMax = xq.txDB.byGasTip.le(delLe)
                                 .ge(AccountNonce.low)
                                 .first.value.effectiveGasTip

      test &"Load/delete with gas price less equal {delMax.toKMG}, " &
          &"out of price range {effGasTips[0].toKMG}..{effGasTips[^1].toKMG}":
        elapNoisy.showElapsed(&"Deleting gas tips less equal {delMax.toKMG}"):
          for itemList in xq.txDB.byGasTip.decItemList(maxPrice = delMax):
            for item in itemList.walkItems:
              count.inc
              check xq.txDB.reject(item,txInfoErrUnspecified)
              check xq.txDB.verify.isOK
        check 0 < count
        check 0 < xq.count.total
        check count + xq.count.total == txList.len
        check xq.count.rejected == count

    block:
      var
        xq = txList.toTxPool(baseFee, noisy)
        count = 0
      let
        delGe = effGasTips[^1] - ((effGasTips[^1] - effGasTips[0]) div 3)
        delMin = xq.txDB.byGasTip.ge(delGe)
                                 .ge(AccountNonce.low)
                                 .first.value.effectiveGasTip

      test &"Load/delete with gas price greater equal {delMin.toKMG}, " &
          &"out of price range {effGasTips[0].toKMG}..{effGasTips[^1].toKMG}":
        elapNoisy.showElapsed(
            &"Deleting gas tips greater than {delMin.toKMG}"):
          for itemList in xq.txDB.byGasTip.incItemList(minPrice = delMin):
            for item in itemList.walkItems:
              count.inc
              check xq.txDB.reject(item,txInfoErrUnspecified)
              check xq.txDB.verify.isOK
        check 0 < count
        check 0 < xq.count.total
        check count + xq.count.total == txList.len
        check xq.count.rejected == count

    block:
      let
        newBaseFee = if baseFee == TxNoBaseFee: 42.GasInt else: baseFee + 7

      test &"Adjust baseFee to {newBaseFee} and back":
        var
          xq = txList.toTxPool(baseFee, noisy)
          baseNonces: seq[AccountNonce] # second level sequence

        # register sequence of nonces
        for nonceList in xq.txDB.byGasTip.incNonceList:
          for itemList in nonceList.incItemList:
            baseNonces.add itemList.first.value.tx.nonce

        xq.setBaseFee(newBaseFee)

        block:
          var
            seen: seq[Hash256]
            tips: seq[GasInt]
          for nonceList in xq.txDB.byGasTip.incNonceList:
            tips.add nonceList.ge(AccountNonce.low).first.value.effectiveGasTip
            for itemList in nonceList.incItemList:
              for item in itemList.walkItems:
                seen.add item.itemID
          check txList.len == xq.txDB.byItemID.nItems
          check txList.len == seen.len
          check tips != effGasTips              # values should have changed
          check seen != txList.mapIt(it.itemID) # order should have changed

        # change back
        xq.setBaseFee(baseFee)

        block:
          var
            seen: seq[Hash256]
            tips: seq[GasInt]
            nces: seq[AccountNonce]
          for nonceList in xq.txDB.byGasTip.incNonceList:
            tips.add nonceList.ge(AccountNonce.low).first.value.effectiveGasTip
            for itemList in nonceList.incItemList:
              nces.add itemList.first.value.tx.nonce
              for item in itemList.walkItems:
                seen.add item.itemID
          check txList.len == xq.txDB.byItemID.nItems
          check txList.len == seen.len
          check tips == effGasTips              # values restored
          check nces == baseNonces              # values restored
          # note: txList[] will be equivalent to seen[] but not necessary
          #       the same


proc runTxPoolTests(noisy = true; baseFee: GasInt) =
  let
    baseInfo = if baseFee != TxNoBaseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Play with pool functions and primitives{baseInfo}":

    block:
      var
        gap: Time
        nItems: int
        xq = txList.toTxPool(baseFee, noisy, gap, nItems,
                             remoteItemsPC = 35, # arbitrary
                             delayMSecs = 100)   # large enough to be found

      test &"Delete about {nItems} expired non-local transactions "&
          &"out of {xq.count.remote}":

        check 0 < nItems
        xq.lifeTime = getTime() - gap

        # evict and pick items from the wastbasket
        discard xq.flushRejects
        xq.inactiveItemsEviction
        let deletedItems = xq.count.rejected

        check xq.count.local == okCount[true]
        check xq.verify.isOK # not: xq.txDB.verify
        check deletedItems == txList.len - xq.count.total

        # make sure that deletion was sort of expected
        let deleteExpextRatio = (deletedItems * 100 / nItems).int
        check deletedItemsRatioBandPC < deleteExpextRatio
        check deleteExpextRatio < (10000 div deletedItemsRatioBandPC)

    # ---------------------------------

    block:
      var
        xq = txList.toTxPool(baseFee, noisy)
        maxAddr: EthAddress
        nAddrItems = 0

        nAddrRemoteItems = 0
        nAddrLocalItems = 0

        nAddrQueuedItems = 0
        nAddrPendingItems = 0
        nAddrStagedItems = 0

      let
        nLocalAddrs = toSeq(xq.localAccounts).len
        nRemoteAddrs = toSeq(xq.txDB.bySender.walkNonceList(local = false)).len

      block:
        test "About half of transactions in largest address group are remotes":

          check 0 < nLocalAddrs
          check 0 < nRemoteAddrs

          # find address with max number of transactions
          for schedList in xq.txDB.bySender.walkSchedList:
            if nAddrItems < schedList.nItems:
              maxAddr = schedList.any.ge(AccountNonce.low).first.value.sender
              nAddrItems = schedList.nItems

          # requite mimimum => there is a status queue with at least 2 entries
          check 3 < nAddrItems

          # count the number of locals and remotes for this address
          nAddrRemoteItems =
                  xq.txDB.bySender.eq(maxAddr).eq(local = false).nItems
          nAddrLocalItems =
                  xq.txDB.bySender.eq(maxAddr).eq(local = true).nItems
          check nAddrRemoteItems + nAddrLocalItems == nAddrItems

          nAddrQueuedItems =
                  xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
          nAddrPendingItems =
                  xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
          nAddrStagedItems =
                  xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
          check nAddrQueuedItems +
                  nAddrPendingItems +
                  nAddrStagedItems == nAddrItems

          # make suke the random assignment made some sense
          check 0 < nAddrQueuedItems
          check 0 < nAddrPendingItems
          check 0 < nAddrStagedItems

          # make sure that local/remote ratio makes sense
          let localRemoteRatio =
             (((nAddrItems - nAddrRemoteItems) * 100) / nAddrRemoteItems).int
          check addrGroupLocalRemotePC < localRemoteRatio
          check localRemoteRatio < (10000 div addrGroupLocalRemotePC)

      block:
        test &"Reassign/move {nAddrRemoteItems} \"remote\" to " &
            &"{nAddrLocalItems} \"local\" items in largest address group " &
            &"with {nAddrItems} items":
          let
            nLocals = xq.count.local
            nRemotes = xq.count.remote
            nMoved = xq.remoteToLocals(maxAddr)

          check xq.txDB.verify.isOK
          check xq.txDB.bySender.eq(maxAddr).eq(local = false).isErr
          check nMoved == nAddrRemoteItems
          check nLocals + nMoved == xq.count.local
          check nRemotes - nMoved == xq.count.remote

          check nRemoteAddrs ==
            1 + toSeq(xq.txDB.bySender.walkNonceList(local = false)).len

          if 0 < nAddrLocalItems:
            check nLocalAddrs == toSeq(xq.localAccounts).len
          else:
            check nLocalAddrs == 1 + toSeq(xq.localAccounts).len

          check nAddrQueuedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
          check nAddrPendingItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
          check nAddrStagedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems

      # --------------------

      block:
        var
          fromNumItems = nAddrQueuedItems
          fromBucketInfo = "queued"
          fromBucket = txItemQueued
          toBucketInfo =  "pending"
          toBucket = txItemPending

        # find the largest from-bucket
        if fromNumItems < nAddrPendingItems:
          fromNumItems = nAddrPendingItems
          fromBucketInfo = "pending"
          fromBucket = txItemPending
          toBucketInfo = "staged"
          toBucket = txItemStaged
        if fromNumItems < nAddrStagedItems:
          fromNumItems = nAddrStagedItems
          fromBucketInfo = "staged"
          fromBucket = txItemStaged
          toBucketInfo = "queued"
          toBucket = txItemQueued

        let
          moveNumItems = fromNumItems div 2

        test &"Reassign {moveNumItems} of {fromNumItems} items "&
            &"from \"{fromBucketInfo}\" to \"{toBucketInfo}\"":
          check 0 < moveNumItems
          check 1 < fromNumItems

          var count = 0
          let ncList = xq.txDB.bySender.eq(maxAddr).eq(fromBucket).value.data
          block collect:
            for itemList in ncList.walkItemList:
              for item in itemList.walkItems:
                count.inc
                check xq.txDB.reassign(item, toBucket)
                if moveNumItems <= count:
                  break collect
          check xq.txDB.verify.isOK

          case fromBucket
          of txItemQueued:
            check nAddrQueuedItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
            check nAddrPendingItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
            check nAddrStagedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
          of txItemPending:
            check nAddrPendingItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
            check nAddrStagedItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
            check nAddrQueuedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
          else:
            check nAddrStagedItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
            check nAddrQueuedItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
            check nAddrStagedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems

      # --------------------

      block:
        var expect: (int,int)
        for schedList in xq.txDB.bySender.walkSchedList:
          expect[0] += schedList.eq(txItemPending).nItems
          expect[1] += schedList.eq(txItemQueued).nItems

        test &"Get global ({expect[0]},{expect[1]}) status via task manager":
          let status = xq.count
          check expect == (status.pending,status.queued)

      # --------------------

      block:
        test &"Delete locals from largest address group so it becomes empty":

          # clear waste basket
          discard xq.flushRejects

          var rejCount = 0
          let addrLocals = xq.txDB.bySender.eq(maxAddr)
                                           .eq(local = true).value.data
          for itemList in addrLocals.walkItemList:
            for item in itemList.walkItems:
              check xq.txDB.reject(item,txInfoErrUnspecified)
              rejCount.inc

          check nLocalAddrs == 1 + toSeq(xq.localAccounts).len
          check xq.count.rejected == rejCount
          check xq.txDB.verify.isOK


proc runTxPackerTests(noisy = true; baseFee: GasInt) =
  let
    baseInfo = if baseFee != TxNoBaseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Block packer tests{baseInfo}":

    block:
      var
        xq = txList.toTxPool(baseFee, noisy)

      test &"Load \"remote\" transactions":
        discard

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc txPoolMain*(noisy = defined(debug)) =
  let baseFee = 42.GasInt
  noisy.runTxLoader(baseFee)
  noisy.runTxBaseTests(baseFee)
  noisy.runTxPoolTests(baseFee)

when isMainModule:
  let
    baseFee = 42.GasInt #  TxNoBaseFee
    captFile0 = "goerli504192.txt.gz"
    captFile1 = "nimbus-eth1/tests" / mainnetCapture
    captFile2 = "mainnet843841.txt.gz"

  let noisy = defined(debug)

  noisy.runTxLoader(
    baseFee,
    dir = "/status", captureFile = captFile1, numTransactions = 1500)

  noisy.runTxBaseTests(baseFee)
  noisy.runTxPoolTests(baseFee)
  noisy.runTxPackerTests(baseFee)

  #noisy.runTxLoader(baseFee, dir = ".")
  #noisy.runTxPoolTests(baseFee)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------