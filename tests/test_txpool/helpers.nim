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
  std/[strformat, sequtils, strutils, times],
  ../../nimbus/utils/keequ,
  ../../nimbus/utils/tx_pool/[tx_item, tx_base],
  ../test_clique/undump, # borrow from clique tools
  eth/[common, keys],
  stint

# Make sure that the runner can stay on public view without the need
# to import `tx_pool/*` sup-modules
export
  keequ,
  tx_base.TxBaseInfo,
  tx_base.bySenderGroups,
  tx_base.byGasPriceDec,
  tx_base.byGasPriceEq,
  tx_base.byGasPriceGe,
  tx_base.byGasPriceGt,
  tx_base.byGasPriceInc,
  tx_base.byGasPriceLe,
  tx_base.byGasPriceLen,
  tx_base.byGasPriceLt,
  tx_base.byGasTipCapDec,
  tx_base.byGasTipCapEq,
  tx_base.byGasTipCapGe,
  tx_base.byGasTipCapGt,
  tx_base.byGasTipCapInc,
  tx_base.byGasTipCapLe,
  tx_base.byGasTipCapLen,
  tx_base.byGasTipCapLt,
  tx_base.bySenderEq,
  tx_base.bySenderLen,
  tx_base.delete,
  tx_base.first,
  tx_base.insert,
  tx_base.last,
  tx_base.next,
  tx_base.prev,
  tx_base.reassign,
  tx_base.toKey,
  tx_base.verify,
  undumpNextGroup

proc pp*(txs: openArray[Transaction]; pfx = ""): string =
  let txt = block:
    var rc = ""
    if 0 < txs.len:
      rc = "[" & txs[0].pp
      for n in 1 ..< txs.len:
        rc &= ";" & txs[n].pp
      rc &= "]"
    rc
  txt.multiReplace([
    (",", &",\n   {pfx}"),
    (";", &",\n  {pfx}")])

proc pp*(txs: openArray[Transaction]; pfxLen: int): string =
  txs.pp(" ".repeat(pfxLen))

proc ppMs*(elapsed: Duration): string =
  result = $elapsed.inMilliSeconds
  let ns = elapsed.inNanoSeconds mod 1_000_000
  if ns != 0:
    # to rounded deca milli seconds
    let dm = (ns + 5_000i64) div 10_000i64
    result &= &".{dm:02}"
  result &= "ms"

proc ppSecs*(elapsed: Duration): string =
  result = $elapsed.inSeconds
  let ns = elapsed.inNanoseconds mod 1_000_000_000
  if ns != 0:
    # to rounded decs seconds
    let ds = (ns + 5_000_000i64) div 10_000_000i64
    result &= &".{ds:02}"
  result &= "s"

proc toKMG*[T](s: T): string =
  proc subst(s: var string; tag, new: string): bool =
    if tag.len < s.len and s[s.len - tag.len ..< s.len] == tag:
      s = s[0 ..< s.len - tag.len] & new
      return true
  result = $s
  for w in [("000", "K"),("000K","M"),("000M","G"),("000G","T"),
            ("000T","P"),("000P","E"),("000E","Z"),("000Z","Y")]:
    if not result.subst(w[0],w[1]):
      return

template showElapsed*(noisy: bool; info: string; code: untyped) =
  let start = getTime()
  code
  if noisy:
    let elpd {.inject.} = getTime() - start
    if 0 < elpd.inSeconds:
      echo "*** ", info, &": {elpd.ppSecs:>4}"
    else:
      echo "*** ", info, &": {elpd.ppMs:>4}"

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# End
