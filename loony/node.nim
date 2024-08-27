import std/atomics

import pkg/arc

import loony/spec
import loony/memalloc

type
  Node* = object
    slots* : array[N, Atomic[uint]]  # Pointers to object
    next*  : Atomic[NodePtr]            # NodePtr - successor node
    ctrl*  : ControlBlock               # Control block for mem recl

when defined(loonyDebug):
  ## Provided are atomic counters and templates/functions which assist measuring
  ## memory leaks with loony. This is primarily used when debugging the algorithm
  ## and is unlikely to be required by end-users. There is a cost in using these
  ## functions as they use costly atomic writes.
  var nodeCounter* {.global.}: Atomic[int]
  var reclaimCounter* {.global.}: Atomic[int]
  var recPathCounter* {.global.}: Atomic[int]
  var enqCounter* {.global.}: Atomic[int]
  var deqCounter* {.global.}: Atomic[int]
  var enqPathCounter* {.global.}: Atomic[int]
  var deqPathCounter* {.global.}: Atomic[int]
  nodeCounter.store(0); reclaimCounter.store(0)
  enqCounter.store(0);  deqCounter.store(0)
  recPathCounter.store(0); enqPathCounter.store(0)
  deqPathCounter.store(0)

  proc echoDebugNodeCounter*() =
    ## This will output the counter
    notice "Node counter: " & $nodeCounter.load()

  template debugNodeCounter*(body: untyped) =
    let (initC, initRec, initRecP, initEnq, initDeq, initEnqP, initDeqP) =
          ( nodeCounter.load(), reclaimCounter.load(),
            recPathCounter.load(), enqCounter.load(),
            deqCounter.load(), enqPathCounter.load(),
            deqPathCounter.load())
    body
    let newC = nodeCounter.load()
    if (newC - initC) > 0:
      warn "Finished block with node count:   " & $(newC - initC)
      notice "Nodes destroyed via reclaim:    " & $(reclaimCounter.load() - initRec)
      notice "Nodes destroyed via deq:        " & $(deqCounter.load() - initDeq)
      notice "Nodes destroyed via enq:        " & $(enqCounter.load() - initEnq)
      notice "Aborted reclaim ops:            " & $(recPathCounter.load() - initRecP)
      notice "Unreclaimed Enq ops:            " & $(enqPathCounter.load() - initEnqP)
      notice "Unreclaimed Deq ops:            " & $(deqPathCounter.load() - initDeqP)

  template incDebugCounter*(): untyped = discard   nodeCounter.fetchAdd(1, moRelaxed)
  template decDebugCounter*(): untyped = discard   nodeCounter.fetchSub(1, moRelaxed)
  template incReclaimCounter*(): untyped = discard reclaimCounter.fetchAdd(1, moRelaxed)
  template incRecPathCounter*(): untyped = discard recPathCounter.fetchAdd(1, moRelaxed)
  template incEnqCounter*(): untyped = discard     enqCounter.fetchAdd(1, moRelaxed)
  template incDeqCounter*(): untyped = discard     deqCounter.fetchAdd(1, moRelaxed)
  template incEnqPathCounter*(): untyped = discard enqPathCounter.fetchAdd(1, moRelaxed)
  template incDeqPathCounter*(): untyped = discard deqPathCounter.fetchAdd(1, moRelaxed)
else:
  proc echoDebugNodeCounter*(expected: int = 0) = discard
  template debugNodeCounter*(body: untyped): untyped = body
  template incDebugCounter*(): untyped = discard
  template decDebugCounter*(): untyped = discard
  template incReclaimCounter*(): untyped = discard
  template incRecPathCounter*(): untyped = discard
  template incEnqCounter*(): untyped = discard
  template incDeqCounter*(): untyped = discard
  template incEnqPathCounter*(): untyped = discard
  template incDeqPathCounter*(): untyped = discard

template toNodePtr*(pt: uint | ptr Node): NodePtr =
  # Convert ptr Node into NodePtr uint
  cast[NodePtr](pt)
template toNode*(pt: NodePtr | uint): Node =
  # NodePtr -> ptr Node and deref
  cast[ptr Node](pt)[]
template toUInt*(node: var Node): uint =
  # Get address to node
  cast[uint](node.addr)
template toUInt*(nodeptr: ptr Node): uint =
  # Equivalent to toNodePtr
  cast[uint](nodeptr)

proc prepareElement*[T](el: var T): uint =
  ## Prepare an item for the queue: ensure that no other threads will free
  ## it, then turn it into an integer and add the WRITER bit.
  when T is ref:
    let owners {.used.} = atomicRC(el, ATOMIC_ACQUIRE)
    when loonyIsolated:
      if owners != 0:
        raise AssertionDefect.newException:
          "pushed ref shared by " & $(1 + owners) & " owners"
  result = cast[uint](el) or WRITER
  wasMoved el

proc fetchNext*(node: NodePtr; moorder: MemoryOrder): NodePtr =
  # get the NodePtr to the next Node, can be converted to a TagPtr of (nptr: NodePtr, idx: 0'u16)
  load(node.toNode.next, order = moorder)

proc fetchAddSlot*(t: var Node, idx: uint16, w: uint, moorder: MemoryOrder): uint =
  ## Fetches the pointer to the object in the slot while atomically
  ## increasing the value by `w`.
  ##
  ## Remembering that the pointer has 3 tail bits clear; these are
  ## reserved and increased atomically to indicate RESUME, READER, WRITER
  ## statuship.
  t.slots[idx].fetchAdd(w, order = moorder)

proc compareAndSwapNext*(t: var Node, expect: var uint, swap: uint): bool =
  t.next.compareExchange(expect, swap, moRelease, moRelaxed)

proc compareAndSwapNext*(t: NodePtr, expect: var uint, swap: uint): bool =
  (toNode t).next.compareExchange(expect, swap, moRelease, moRelaxed)

proc `=destroy`*(n: var Node) =
  decDebugCounter()
  deallocAligned(n.addr, NODEALIGN.int)
proc deallocNode*(n: ptr Node) =
  decDebugCounter()
  deallocAligned(n, NODEALIGN.int)

proc allocNode*(): ptr Node =
  incDebugCounter()
  cast[ptr Node](allocAligned0(sizeof(Node), NODEALIGN.int))

proc allocNode*[T](pel: T): ptr Node =
  result = allocNode()
  result.slots[0].store(pel)

proc tryReclaim*(node: var Node; start: uint16) =
  block done:
    for i in start..<N:
      template s: Atomic[uint] = node.slots[i]
      if (s.load(order = moAcquire) and CONSUMED) != CONSUMED:
        var prev = s.fetchAdd(RESUME, order = moRelaxed) and CONSUMED
        if prev != CONSUMED:
          incRecPathCounter()
          break done
    var flags = node.ctrl.fetchAddReclaim(SLOT)
    if flags == (ENQ or DEQ):
      `=destroy` node
      incReclaimCounter()

proc incrEnqCount*(node: var Node; final: uint16 = 0) =
  var mask = node.ctrl.fetchAddTail((final.uint32 shl 16) + 1)
  template finalCount: uint16 =
    if final == 0:
      getHigh mask
    else:
      final
  if finalCount == (mask.uint16 and MASK) + 1:
    if node.ctrl.fetchAddReclaim(ENQ) == (DEQ or SLOT):
      `=destroy` node
      incEnqCounter()
  else:
    incEnqPathCounter()

proc incrDeqCount*(node: var Node; final: uint16 = 0) =
  incDeqPathCounter()
  var mask = node.ctrl.fetchAddHead((final.uint32 shl 16) + 1)
  template finalCount: uint16 =
    if final == 0:
      getHigh mask
    else:
      final
  if finalCount == (mask.uint16 and MASK) + 1:
    if node.ctrl.fetchAddReclaim(DEQ) == (ENQ or SLOT):
      `=destroy` node
      incDeqCounter()
  else:
    incDeqPathCounter()
