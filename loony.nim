## This contains the LoonyQueue object and associated push/pop operations.
##
## There is a detailed explanation of the algorithm operation within the src
## files if you are having issues or want to contribute.

import std/atomics

import pkg/arc

import loony/spec
import loony/node

export
  node.echoDebugNodeCounter, node.debugNodeCounter
# sprinkle some raise defect
# raise Defect(nil) | yes i am the
# raise Defect(nil) | salt bae of defects
# raise Defect(nil) |
# raise Defect(nil) | I am defect bae
# raise Defect(nil) |
# and one more for haxscrampers pleasure
# raise Defect(nil)

type

  LoonyQueue*[T] = ref LoonyQueueImpl[T]
  LoonyQueueImpl*[T] = object
    head     : Atomic[TagPtr]     ## Whereby node contains the slots and idx
    tail     : Atomic[TagPtr]     ## is the uint16 index of the slot array
    currTail : Atomic[NodePtr]    ## 8 bytes Current NodePtr

  ## Result types for the private
  ## advHead and advTail functions
  AdvTail = enum
    AdvAndInserted  # 0000_0000
    AdvOnly         # 0000_0001
  AdvHead = enum
    QueueEmpty      # 0000_0000
    Advanced        # 0000_0001

#[
  TagPtr is an alias for 8 byte uint (pointer). We reserve a portion of
  the tail to contain the index of the slot to its corresponding node
  by aligning the node pointers on allocation. Since the index value is
  stored in the same memory word as its associated node pointer, the FAA
  operations could potentially affect both values if too many increments
  were to occur. This is accounted for in the algorithm and with space
  for overflow in the alignment. See Section 5.2 for the paper to see
  why an overflow would prove impossible except under extraordinarily
  large number of thread contention.
]#

template nptr(tag: TagPtr): NodePtr = toNodePtr(tag and PTRMASK)
template node(tag: TagPtr): var Node = cast[ptr Node](nptr(tag))[]
template idx(tag: TagPtr): uint16 = uint16(tag and TAGMASK)
proc toStrTuple*(tag: TagPtr): string =
  var res = (nptr:tag.nptr, idx:tag.idx)
  return $res

proc fetchTail(queue: LoonyQueue): TagPtr =
  ## get the TagPtr of the tail (nptr: NodePtr, idx: uint16)
  TagPtr load(queue.tail, order = moRelaxed)

proc fetchHead(queue: LoonyQueue): TagPtr =
  ## get the TagPtr of the head (nptr: NodePtr, idx: uint16)
  TagPtr load(queue.head, order = moRelaxed)

proc fetchCurrTail(queue: LoonyQueue): NodePtr {.used.} =
  # get the NodePtr of the current tail
  cast[NodePtr](load(queue.currTail, moRelaxed))

# Bug #11 - Using these as templates would cause errors unless the end user
# imported std/atomics or we export atomics.
# For the sake of not polluting the users namespace I have changed these into procs.
# Atomic inc of idx in (nptr: NodePtr, idx: uint16)
proc fetchIncTail(queue: LoonyQueue): TagPtr =
  cast[TagPtr](queue.tail.fetchAdd(1, order = moAcquire))
proc fetchIncHead(queue: LoonyQueue): TagPtr =
  cast[TagPtr](queue.head.fetchAdd(1, order = moAcquire))

proc compareAndSwapTail(queue: LoonyQueue; expect: var uint; swap: uint | TagPtr): bool =
  queue.tail.compareExchange(expect, swap, moRelease, moRelaxed)

proc compareAndSwapHead(queue: LoonyQueue; expect: var uint; swap: uint | TagPtr): bool =
  queue.head.compareExchange(expect, swap, moRelease, moRelaxed)

proc compareAndSwapCurrTail(queue: LoonyQueue; expect: var uint;
                            swap: uint | TagPtr): bool {.used.} =
  queue.currTail.compareExchange(expect, swap, moRelease, moRelaxed)

proc `=destroy`*[T](x: var LoonyQueueImpl[T]) =
  ## Destroy is completely operated on the basis that no other threads are
  ## operating on the queue at the same time. To not follow this will result in
  ## SIGSEGVs and undefined behaviour.
  var loadedLine: int # we want to track what cache line we have loaded and
                      # ensure we perform an atomic load at least once on each cache line
  var headNodeIdx: (NodePtr, uint16)
  var tailNode: ptr Node
  var tailIdx: uint16
  var slotptr: ptr uint
  var slotval: uint
  block:

    template getHead: untyped =
      let tptr = x.head.load()
      headNodeIdx = (tptr.nptr, tptr.idx)

    template getTail: untyped =
      if tailNode.isNil():
        let tptr = x.tail.load()
        tailNode = cast[ptr Node](tptr.nptr)
        tailIdx = tptr.idx
        loadedLine = cast[int](tailNode)
      else:
        let oldNode = tailNode
        tailNode = cast[ptr Node](tailNode.next.load().nptr())
        tailIdx = 0'u16
        deallocNode oldNode

    template loadSlot: untyped =
      slotptr = cast[ptr uint](tailNode.slots[tailIdx].addr())
      if (loadedLine + 64) < cast[int](slotptr):
        slotval = slotptr.atomicLoadN(ATOMIC_RELAXED)
        loadedLine = cast[int](slotptr)
      elif not slotptr.isNil():
        slotval = slotptr[]
      else:
        slotval = 0'u

    template truthy: bool =
      (cast[NodePtr](tailNode), tailIdx) == headNodeIdx
    template idxTruthy: bool =
      if cast[NodePtr](tailNode) == headNodeIdx[1]:
        tailIdx < N
      else:
        tailIdx <= headNodeIdx[1]

    getHead()
    getTail()
    if (loadedLine mod 64) != 0:
      loadedLine = loadedLine - (loadedLine mod 64)

    while not truthy:
      while idxTruthy:
        loadSlot()
        if (slotval and spec.WRITER) == spec.WRITER:
          if (slotval and CONSUMED) == CONSUMED:
            inc tailIdx
          elif (slotval and PTRMASK) != 0'u:
            var el = cast[T](slotval and PTRMASK)
            when T is ref:
              GC_unref el
            else:
              `=destroy`(el)
            inc tailIdx
        else:
          break
      getTail()
      if tailNode.isNil():
        break
    if not tailNode.isNil():
      deallocNode(tailNode)

#[
  Both enqueue and dequeue enter FAST PATH operations 99% of the time,
  however in cases we enter the SLOW PATH operations represented in both
  enq and deq by advTail and advHead respectively.

  This path requires the threads to first help updating the linked list
  struct before retrying and entering the fast path in the next attempt.
]#

proc advTail[T](queue: LoonyQueue[T]; pel: uint; tag: TagPtr): AdvTail =
  # Modified version of Michael-Scott algorithm
  # Attempt allocate & append new node on previous tail
  var origTail = tag.nptr
  block done:
    while true:
      # First we get the current tail
      var currTTag = queue.fetchTail()
      if origTail != currTTag.nptr:
        # Another thread has appended a new node already. Help clean node up.
        incrEnqCount origTail.toNode
        result = AdvOnly
        break done
      # Get current tails next node
      var next = fetchNext(origTail, moRelaxed)
      if cast[ptr Node](next).isNil():
        # Prepare the new node with our element in it
        var node = allocNode pel
        var null: uint
        if origTail.compareAndSwapNext(null, node.toUint):
          # Successfully inserted our node into current/original nodes next.
          # Since we have already inserted a slot, we try to replace the queue's
          # tail tagptr with the new node, with an index of 1.
          while not queue.compareAndSwapTail(currTTag, node.toUint + 1):
            # Loop is not relevant to compareAndSwapStrong; consider weak swap?
            if currTTag.nptr != origTail:
              # REVIEW This does not make sense unless we reload the
              #        the current tag?
              incrEnqCount origTail.toNode
              result = AdvAndInserted
              break done
          # Successfully updated the queue.tail and node.next with our new node
          # Help clean up this node
          incrEnqCount(origTail.toNode, currTTag.idx - N)
          result = AdvAndInserted
          break done
        # Another thread inserted a new node before we could; deallocate and try
        # again. New currTTag will mean we enter the first if condition statement.
        deallocNode node
      else:
        # The next node has already been set, help the thread to set the next
        # node in the queue tail
        while not queue.tail.compareExchange(currTTag, next + 1):
          # Loop is not relevant to CAS-strong; consider weak CAS?
          if currTTag.nptr != origTail:
            # REVIEW this does not make sense unless we reload the current tag?
            incrEnqCount origTail.toNode
            result = AdvOnly
            break done
        # Successfully updated the queue.tail with another threads node; we
        # help clean up this node and thread is free to adv and try push again
        incrEnqCount(origTail.toNode, currTTag.idx - N)
        result = AdvOnly
        break done

proc advHead(queue: LoonyQueue; curr, h, t: var TagPtr): AdvHead =
  if h.idx == N:
    # This should reliably trigger reclamation of the node memory on the last
    # read of the head.
    tryReclaim(h.node, 0'u8)
  result =
    if t.nptr == h.nptr:
      incrDeqCount h.node
      QueueEmpty
    else:
      var next = fetchNext(h.nptr, moAcquire)
      # Equivalent to (nptr: NodePtr, idx: idx+=1)
      curr += 1
      block done:
        while not queue.compareAndSwapHead(curr, next):
          if curr.nptr != h.nptr:
            incrDeqCount h.node
            break done
        incrDeqCount(h.node, curr.idx - N)
      Advanced

#[
  Fundamentally, both enqueue and dequeue operations attempt to
  exclusively reserve access to a slot in the array of their associated
  queue node by automatically incremementing the appropriate index value
  and retrieving the previous value of the index as well as the current
  node pointer.

  Threads that retrieve an index i < N (length of the slots array) gain
  *exclusive* rights to perform either write/consume operation on the
  corresponding slot.

  This guarantees there can only be exactly one of each for any given
  slot.

  Where i < N, we use FAST PATH operations. These operations are
  designed to be as fast as possible while only dealing with memory
  contention in rare edge cases.

  if not i < N, we enter SLOW PATH operations. See AdvTail and AdvHead
  above.

  Fetch And Add (FAA) primitives are used for both incrementing index
  values as well as performing read(consume) and write operations on
  reserved slots which drastically improves scalability compared to
  Compare And Swap (CAS) primitives.

  Note that all operations on slots must modify the slots state bits to
  announce both operations completion (in case of a read) and also makes
  determining the order in which two operations occured possible.
]#

proc pushImpl[T](queue: LoonyQueue[T], el: sink T,
                    forcedCoherence: static bool = false) =
  assert not queue.isNil(), "The queue has not been initialized"
  # Begin by tagging pointer el with WRITER bit and increasing the ref
  # count if necessary
  var pel = prepareElement el
  # Ensure all writes in STOREBUFFER are committed. By far the most costly
  # primitive; it will be preferred while proving safety before working
  # towards optimization by atomic reads/writes of cache lines related to el
  when forcedCoherence:
    atomicThreadFence(ATOMIC_RELEASE)
  while true:
    # Enq proc begins with incr the index of node in TagPtr
    var tag = queue.fetchIncTail()
    if likely(tag.idx < N):
      # FAST PATH OPERATION - 99% of push will enter here; we want the minimal
      # amount of necessary operations in this path.
      # Perform a FAA on our reserved slot which should be 0'd.
      let prev = fetchAddSlot(tag.node, tag.idx, pel, moAcquire)
      case prev
      of 0, RESUME:
        break           # the slot was empty; we're good to go

      # If READER bit already set,then the corresponding deq op arrived
      # early; we must consequently abandon the slot and retry.

      of RESUME or READER:
        # Checking RESUME bit pertains to memory reclamation mechanism;
        # only relevant in rare edge cases in which the Enq op significantly
        # delayed and lags behind other ops on the same node
        tryReclaim(tag.node, tag.idx + 1)
      else:
        # Should the case above occur or we detect that the slot has been
        # filled by some gypsy magic then we will retry on the next loop.
        discard

    else:
      # SLOW PATH; modified version of Michael-Scott algorithm
      case queue.advTail(pel, tag)
      of AdvAndInserted:
        break
      of AdvOnly:
        discard



proc push*[T](queue: LoonyQueue[T], el: sink T) =
  ## Push an item onto the end of the LoonyQueue.
  ## This operation ensures some level of cache coherency using atomic thread fences.
  ##
  ## Use unsafePush to avoid this cost.
  pushImpl(queue, el, forcedCoherence = true)

proc unsafePush*[T](queue: LoonyQueue[T], el: sink T) =
  ## Push an item onto the end of the LoonyQueue.
  ## Unlike push, this operation does not use atomic thread fences. This means you
  ## may get undefined behaviour if the receiving thread has old cached memory
  ## related to this element
  pushImpl(queue, el, forcedCoherence = false)

proc isEmptyImpl(head, tail: TagPtr): bool =
  if head.idx >= N or head.idx >= tail.idx:
    head.nptr == tail.nptr
  else:
    false

proc isEmpty*(queue: LoonyQueue): bool =
  ## This operation should only be used by internal code. The response for this
  ## operation is not precise.
  let head = queue.fetchHead()
  let tail = queue.fetchTail()
  isEmptyImpl(head, tail)

proc popImpl[T](queue: LoonyQueue[T]; forcedCoherence: static bool = false): T =
  assert not queue.isNil(), "The queue has not been initialised"
  while true:
    # Before incr the deq index, init check performed to determine if queue is empty.
    # Ensure head is loaded last to keep mem hot
    var tail = queue.fetchTail()
    var curr = queue.fetchHead()
    if isEmptyImpl(curr, tail):
      # Queue was empty; nil can be caught in cps w/ "while cont.running"
      when T is ref or T is ptr:
        return nil
      else:
        return default(T)

    var head = queue.fetchIncHead()
    if likely(head.idx < N):
      # FAST PATH OPS
      var prev = fetchAddSlot(head.node, head.idx, READER, moRelease)
      # Last slot in a node - init reclaim proc; if WRITER bit set then upper bits
      # contain a valid pointer to an enqd el that can be returned (see enqueue)
      if not unlikely((prev and SLOTMASK) == 0):
        if (prev and spec.WRITER) != 0:
          if unlikely((prev and RESUME) != 0):
            tryReclaim(head.node, head.idx + 1)

          # Ideally before retrieving the ref object itself, we want to allow
          # CPUs to communicate cache line changes and resolve invalidations
          # to dirty memory.
          when forcedCoherence:
            atomicThreadFence(ATOMIC_ACQUIRE)
          # CPU halt and clear STOREBUFFER; overwritten cache lines will be
          # syncd and invalidated ensuring fresh memory from this point in line
          # with the PUSH operations atomicThreadFence(ATOMIC_RELEASE)
          # This is the most costly primitive fill the requirement and will be
          # preferred to prove safety before optimising by targetting specific
          # cache lines with atomic writes and loads rather than requiring a
          # CPU to completely commit its STOREBUFFER

          result = cast[T](prev and SLOTMASK)  # cast is effectively GC_ref
          when T is ref:
            # ideally, no one knows about this reference, so we'll
            # make an adjustment here to counter the cast incref and
            # afford ordering elsewhere
            let owners {.used.} = atomicDecRef(result, ATOMIC_ACQ_REL)
            # since we have some extra information here, we'll throw
            # in a guard which should only trigger in the event the
            # ownership was corrupted while the ref was in the queue
            when loonyIsolated:
              if owners != 1:
                raise AssertionDefect.newException:
                  "popped ref shared by " & $owners & " owners"
          break
    else:
      # SLOW PATH OPS
      case queue.advHead(curr, head, tail)
      of Advanced:
        discard
      of QueueEmpty:
        break

proc pop*[T](queue: LoonyQueue[T]): T =
  ## Remove and return to the caller the next item in the LoonyQueue.
  ## This operation ensures some level of cache coherency using atomic thread fences.
  ##
  ## Use unsafePop to avoid this cost.
  popImpl(queue, forcedCoherence = true)

proc unsafePop*[T](queue: LoonyQueue[T]): T =
  ## Remove and return to the caller the next item in the LoonyQueue.
  ## Unlike pop, this operation does not use atomic thread fences. This means you
  ## may get undefined behaviour if the caller has old cached memory that is
  ## related to the item.
  popImpl(queue, forcedCoherence = false)

#[
  Consumed slots have been written to and then read. If a concurrent
  dequeue operation outpaces the corresponding enqueue operation then both
  operations have to abandon and try again. Once all slots in the node
  have been consumed or abandoned, the node is considered drained and
  unlinked from the list. Node can be reclaimed and de-allocated.

  Queue manages an enqueue index and a dequeue index. Each are modified
  by fetchAndAdd; gives thread reserves previous index for itself which
  may be used to address a slot in the respective nodes array.

  both node pointers are tagged with their assoc index value ->
  they store both address to respective node as well as the current
  index value in the same memory word.

  Requires a sufficient number of available bits that are not used to
  present the nodes addresses themselves.
]#

proc initLoonyQueue*(q: LoonyQueue) =
  ## Initialize an existing LoonyQueue.
  var headTag = cast[uint](allocNode())
  var tailTag = headTag
  q.head.store headTag
  q.tail.store tailTag
  q.currTail.store tailTag
  for i in 0..<N:
    var h = load headTag.toNode().slots[i]
    var t = load tailTag.toNode().slots[i]
    assert h == 0, "Slot found to not be nil on initialisation"
    assert t == 0, "Slot found to not be nil on initialisation"
  # Allocate the first nodes on initialisation to optimise use.

proc initLoonyQueue*[T](): LoonyQueue[T] {.deprecated: "Use newLoonyQueue instead".} =
  ## Return an initialized LoonyQueue.
  # TODO destroy proc
  new result
  initLoonyQueue result

proc newLoonyQueue*[T](): LoonyQueue[T] =
  ## Return an intialized LoonyQueue.
  new result
  initLoonyQueue result
