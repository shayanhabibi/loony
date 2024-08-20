import std/atomics

const
  loonyNodeAlignment {.intdefine.} = 11
  loonySlotCount {.intdefine.} = 1024

  loonyIsolated* {.booldefine.} = false  ## Indicate that loony should
  ## assert that all references passing through the queue have a single
  ## owner.  Note that in particular, child Continuations have cycles,
  ## which will trigger a failure of this assertion.

static:
  doAssert (1 shl loonyNodeAlignment) > loonySlotCount,
    "Your LoonySlot count exceeds your alignment!"

const
  ## Slot flag constants
  UNINIT*   =   uint8(   0   ) # 0000_0000
  RESUME*   =   uint8(1      ) # 0000_0001
  WRITER*   =   uint8(1 shl 1) # 0000_0010
  READER*   =   uint8(1 shl 2) # 0000_0100
  CONSUMED* =  READER or WRITER# 0000_0110

  SLOT*     =   uint8(1      ) # 0000_0001
  DEQ*      =   uint8(1 shl 1) # 0000_0010
  ENQ*      =   uint8(1 shl 2) # 0000_0100
  #
  N*        =         loonySlotCount      # Number of slots per node in the queue
  #
  TAGBITS*   : uint = loonyNodeAlignment  # Each node must be aligned to this value
  NODEALIGN* : uint = 1 shl TAGBITS       # in order to store the required number of
  TAGMASK*   : uint = NODEALIGN - 1       # tag bits in every node pointer
  PTRMASK*   : uint = high(uint) xor TAGMASK
  # Ref-count constants
  SHIFT* = 16      # Shift to access 'high' 16 bits of uint32
  MASK*  = 0xFFFF  # Mask to access 'low' 16 bits of uint32
  #
  SLOTMASK*  : uint = high(uint) xor (RESUME or WRITER or READER)

type
  NodePtr* = uint
  TagPtr* = uint  ##
    ## Aligned pointer with 12 bit prefix containing the tag.
    ## Access using procs nptr and idx
  ControlMask* = uint32

  ## Control block for memory reclamation
  ControlBlock* = object
    ## high uint16 final observed count of slow-path enqueue ops
    ## low uint16: current count
    headMask* : Atomic[ControlMask]     # (uint16, uint16)  4 bytes
    ## high uint16, final observed count of slow-path dequeue ops,
    ## low uint16: current count
    tailMask* : Atomic[ControlMask]     # (uint16, uint16)  4 bytes
    ## Bitmask for storing current reclamation status
    ## All 3 bits set = node can be reclaimed
    reclaim*  : Atomic[uint8]     #                   1 byte

proc getHigh*(mask: ControlMask): uint16 =
  (mask shr SHIFT).uint16

proc getLow*(mask: ControlMask): uint16 =
  mask.uint16

proc fetchAddTail*(ctrl: var ControlBlock, v: uint32 = 1): ControlMask =
  ctrl.tailMask.fetchAdd(v, order = moRelaxed)

proc fetchAddHead*(ctrl: var ControlBlock, v: uint32 = 1): ControlMask =
  ctrl.headMask.fetchAdd(v, order = moRelaxed)

proc fetchAddReclaim*(ctrl: var ControlBlock, v: uint8 = 1): uint8 =
  ctrl.reclaim.fetchAdd(v, order = moAcquireRelease)

when defined(loonyDebug):
  import std/logging
  export debug, info, notice, warn, error, fatal
else:
  # use the `$` converter just to ensure that debugging statements compile
  template debug*(args: varargs[untyped, `$`]): untyped = discard
  template info*(args: varargs[untyped, `$`]): untyped = discard
  template notice*(args: varargs[untyped, `$`]): untyped = discard
  template warn*(args: varargs[untyped, `$`]): untyped = discard
  template error*(args: varargs[untyped, `$`]): untyped = discard
  template fatal*(args: varargs[untyped, `$`]): untyped = discard
