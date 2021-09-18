import std/atomics
import "."/[alias, constants, controlblock, node]
# Import the holy one
import pkg/cps

# sprinkle some raise defect
# raise Defect(nil) | yes i am the
# raise Defect(nil) | salt bae of defects
# raise Defect(nil) | 
# raise Defect(nil) | I am defect bae 
# raise Defect(nil) |
# and one more for haxscrampers pleasure
# raise Defect(nil)

type
  LoonyQueue*[T] = object
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

## TagPtr is an alias for 8 byte uint (pointer). We reserve a portion of the
## tail to contain the index of the slot to its corresponding node by aligning
## the node pointers on allocation. Since the index value is stored in the
## same memory word as its associated node pointer, the FAA operations could
## potentially affect both values if too many increments were to occur.
## This is accounted for in the algorithm and with space for overflow in the
## alignment.
## See Section 5.2 for the paper to see why an overflow would prove impossible
## except under extraordinarily large number of thread contention.

proc nptr(tag: TagPtr): NodePtr = toNodePtr(tag and PTRMASK)
proc idx(tag: TagPtr): uint16 = uint16(tag and TAGMASK)
proc tag(tag: TagPtr): uint16 = tag.idx
proc toStrTuple*(tag: TagPtr): string =
  var res = (nptr:tag.nptr, idx:tag.idx)
  return $res

template fetchTail(queue: var LoonyQueue): TagPtr =
  ## get the TagPtr of the tail (nptr: NodePtr, idx: uint16)
  TagPtr(load queue.tail)

template fetchHead(queue: var LoonyQueue): TagPtr =
  ## get the TagPtr of the head (nptr: NodePtr, idx: uint16)
  TagPtr(load queue.head)

template maneAndTail(queue: var LoonyQueue): (TagPtr, TagPtr) =
  (fetchHead queue, fetchTail queue)
template tailAndMane(queue: var LoonyQueue): (TagPtr, TagPtr) =
  (fetchTail queue, fetchHead queue)

template fetchCurrTail(queue: var LoonyQueue): NodePtr =
  ## get the NodePtr of the current tail
  cast[NodePtr](load queue.currTail)

template fetchIncTail(queue: var LoonyQueue): TagPtr =
  ## Atomic fetchAdd of Tail TagPtr - atomic inc of idx in (nptr: NodePtr, idx: uint16)
  cast[TagPtr](queue.tail.fetchAdd(1))

template fetchIncHead(queue: var LoonyQueue): TagPtr =
  ## Atomic fetchAdd of Head TagPtr - atomic inc of idx in (nptr: NodePtr, idx: uint16)
  cast[TagPtr](queue.head.fetchAdd(1))

template compareAndSwapTail(queue: var LoonyQueue, expect: var uint, swap: uint | TagPtr): bool =
  queue.tail.compareExchange(expect, swap)
  
template compareAndSwapHead(queue: var LoonyQueue, expect: var uint, swap: uint | TagPtr): bool =
  queue.head.compareExchange(expect, swap)

## Both enqueue and dequeue enter FAST PATH operations 99% of the time,   
## however in cases we enter the SLOW PATH operations represented in both 
## enq and deq by advTail and advHead respectively.                       
##
## This path requires the threads to first help updating the linked list  
## struct before retrying and entering the fast path in the next attempt. 

proc advTail[T](queue: var LoonyQueue[T]; el: T; t: NodePtr): AdvTail =
  ## Modified Michael-Scott algorithm
  var null = 0'u
  while true:
    var tail = queue.fetchTail
    if t != tail.nptr:
      t.incrEnqCount()
      result = AdvOnly
      break
    var next = t.fetchNext()
    if cast[ptr Node](next).isNil():
      var node = allocNode el
      null = 0'u
      if t.compareAndSwapNext(null, node):
        null = 0'u
        var tag: TagPtr = node + 1  # Translates to (nptr: node, idx: 1)
        block done:
          while not queue.compareAndSwapTail(null, tag): # T11
            if t != tail.nptr:
              t.incrEnqCount()
              break done
          t.incrEnqCount(tail.idx - N)
        result = AdvAndInserted
        break
      else:
        deallocNode(node)
    else: # T20
      result = AdvOnly
      null = 0'u
      block done:
        # next+1 translates to (nptr: next, idx: 1)
        while not queue.compareAndSwapTail(null, next+1):
          if t != tail.nptr:
            t.incrEnqCount()
            break done
        t.incrEnqCount(tail.idx - (N-1))
      break

proc advHead(queue: var LoonyQueue; curr: var TagPtr;
             h, t: NodePtr): AdvHead =
  h.tryReclaim(0'u8)  # As done in cpp impl
  var next = fetchNext h
  result =
    if cast[ptr Node](next).isNil() or (t == h):
      h.incrDeqCount()
      QueueEmpty
    else:
      # Equivalent to (nptr: NodePtr, idx: idx+=1)
      curr += 1
      # equivalent to (nptr: next, idx: 0)
      block done:
        while not queue.compareAndSwapHead(curr, next.nptr):
          if curr.nptr != h:
            h.incrDeqCount()
            break done
        h.incrDeqCount(curr.idx - (N-1))
      Advanced

## Fundamentally, both enqueue and dequeue operations attempt to
## exclusively reserve access to a slot in the array of their associated
## queue node by automatically incremementing the appropriate index value
## and retrieving the previous value of the index as well as the current
## node pointer.
##
## Threads that retrieve an index i < N (length of the slots array) gain
## *exclusive* rights to perform either write/consume operation on the
## corresponding slot.
##
## This guarantees there can only be exactly one of each for any given
## slot.
##
## Where i < N, we use FAST PATH operations. These operations are
## designed to be as fast as possible while only dealing with memory
## contention in rare edge cases.
##
## if not i < N, we enter SLOW PATH operations. See AdvTail and AdvHead
## above.
##
## Fetch And Add (FAA) primitives are used for both incrementing index
## values as well as performing read(consume) and write operations on
## reserved slots which drastically improves scalability compared to
## Compare And Swap (CAS) primitives.
##
## Note that all operations on slots must modify the slots state bits to
## announce both operations completion (in case of a read) and also makes
## determining the order in which two operations occured possible.

proc push*[T](queue: var LoonyQueue[T], el: T) =
  while true:
    ## The enqueue procedure begins with incrementing the
    ## index of the associated node in the TagPtr
    var tag = fetchIncTail(queue)
    if likely(tag.idx < N):
      ## We begin by tagging the pointer for el with a WRITER
      ## bit and then perform a FAA.
      var w   : uint = prepareElement(el) 
      let prev: uint = fetchAddSlot(tag.nptr, tag.idx, w)
      if prev > 0:
        debugEcho "FAST PATH PUSH encountered pre-filled slot"
        debugEcho "prefilled: ", prev.repr
        debugEcho "index: ", tag.idx
        debugEcho "new val: ", w.repr

      ## Since we are assured that the slots would be 0'd, the slots
      ## value should be evaluated to be less than 0 (RESUME = 1).
      if prev <= RESUME:
        break

      ## If however we assess that the READER bit was already set before
      ## we arrived, then the corresponding dequeue operation arrived
      ## too early and we must consequently abandon the slot and retry
      if prev == (READER or RESUME):
        ## Checking for the presence of the RESUME bit only pertains to
        ## the memory reclamation mechanism and is only relevant
        ## in rare edge cases in which the enqueue operation
        ## is significantly delayed and lags behind most other operations
        ## on the same node.
        tryReclaim(tag.nptr, tag.idx + 1)

      ## Should the case above occur or we detect that the slot has been  
      ## filled by some gypsy magic then we will retry on the next goround.

    else:

      # Slow path; modified version of Michael-Scott algorithm; see
      # advTail above

      case queue.advTail(el, tag.nptr)
      of AdvAndInserted:
        break
      of AdvOnly:
        discard

proc isEmptyImpl(head, tail: TagPtr): bool {.inline.} =
  if head.idx >= N or head.idx >= tail.idx:
    result = head.nptr == tail.nptr

proc isEmpty*(queue: var LoonyQueue): bool =
  let (head, tail) = maneAndTail queue
  isEmptyImpl(head, tail)

proc pop*[T](queue: var LoonyQueue[T]): T =
  while true:
    ## Before incrementing the dequeue index, an initial check must be    
    ## performed to determine if the queue is empty.                      
    ## Ensure head is loaded last to keep mem hot
    var (tail, curr) = tailAndMane queue
    if isEmptyImpl(curr, tail):
      return nil # Um ok

    var head = queue.fetchIncHead()
    if likely(head.idx < N):
      var prev = fetchAddSlot(head.nptr, head.idx, READER)
      # On the last slot in a node, we initiate the reclaim
      # procedure; if the writer bit is set then the upper bits
      # must contain a valid pointer to an enqueued element
      # that can be returned (see enqueue)
      if unlikely((prev and SLOTMASK) == 0): continue
      # if i == N-1: ## why do we abandon the last index? do we do the same for the push?
      #   h.tryReclaim(0'u8)
      #   continue  ## REVIEW - This operation makes no sense to me and it wasn't in the cpp imp so I killed it
      if (prev and constants.WRITER) != 0:
        if unlikely((prev and RESUME) != 0):
          tryReclaim(head.nptr, head.idx + 1)
        result = cast[T](prev and SLOTMASK)
        assert result != nil
        GC_unref result
        break
    else:
      case queue.advHead(curr, head.nptr, tail.nptr)
      of Advanced:
        discard
      of QueueEmpty:
        break           # big oof

## Consumed slots have been written to and then read. If a concurrent     
## deque operation outpaces the corresponding enqueue operation then both 
## operations have to abandon and try again. Once all slots in the node   
## have been consumed or abandoned, the node is considered drained and    
## unlinked from the list. Node can be reclaimed and de-allocated.        
##
## Queue manages an enqueue index and a dequeue index. Each are modified  
## by fetchAndAdd; gives thread reserves previous index for itself which  
## may be used to address a slot in the respective nodes array.           
##
## ANCHOR both node pointers are tagged with their assoc index value ->   
## they store both address to respective node as well as the current      
## index value in the same memory word.                                   
##
## Requires a sufficient number of available bits that are not used to    
## present the nodes addresses themselves.                                

proc initLoonyQueue*(q: var LoonyQueue) =
  ## Initialize an existing LoonyQueue.
  var headTag = allocNode()
  var tailTag = headTag
  q.head.store headTag
  q.tail.store tailTag
  q.currTail.store tailTag
  for i in 0..<N:
    var h = load headTag.toNode().slots[i]
    var t = load tailTag.toNode().slots[i]
    assert h == 0, "Slot found to not be nil on initialisation"
    assert t == 0, "Slot found to not be nil on initialisation"
  # I mean the enqueue and dequeue pretty well handle any issues with
  # initialising, but I might as well help allocate the first ones right?

proc initLoonyQueue*(): LoonyQueue =
  ## Return an initialized LoonyQueue.
  # So I should definitely have a destroy proc to clear the nodes but i
  # do that later
  initLoonyQueue result