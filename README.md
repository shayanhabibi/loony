
<div align="center">
	<br>
	<a href="https://github.com/nim-works/loony">
		<img src="papers/header.svg" width="800" height="200" alt="Loony">
	</a>
	<br>

[![Test Matrix](https://github.com/disruptek/cps/workflows/CI/badge.svg)](https://github.com/shayanhabibi/loony/actions?query=workflow%3ACI)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/shayanhabibi/loony?style=flat)](https://github.com/shayanhabibi/loony/releases/latest)
![Minimum supported Nim version](https://img.shields.io/badge/nim-1.5.1%2B-informational?style=flat&logo=nim)
[![License](https://img.shields.io/github/license/shayanhabibi/loony?style=flat)](#license)
</div>

<!-- # Loony -->
>*"Don't let me block you" - Araq*
>
>*"We didn't have a good story about migrating continuations between threads." - Disruptek*

Have you ever asked yourself what would a lock-free MPMC queue look like in nim?

What about a lock-free MPMC queue designed on an algorithm built for speed and memory safety?

What about that algorithm implemented by some ***loonatics***?

Enter **Loony**

>*"C'mon man... 24,000 threads and 500,000,000 continuations... which are written in "normal" nim." - Disruptek*
>
>*"OK, time to get my monies worth from all my cores" - saem*
>
>*"My eyes are bleeding" - cabboose*

## About

> A massive thank you to the author Oliver Giersch who proposed this algorithm and for being so kind as to have a look at our implementation and review it! We wish nothing but the best for the soon to be Dr Giersch.


Loony is a 100% Nim-lang implementation of the algorithm depicted by Giersch & Nolte in ["Fast
and Portable Concurrent FIFO Queues With Deterministic Memory Reclamation"](papers/GierschEtAl.pdf).

The algorithm was chosen to help progress the concurrency story of [CPS](https://github.com/nim-works/cps) for which this was bespokingly made.

After adapting the algorithm to nim CPS, disruptek adapted the queue for **any ref object** and was instrumental in ironing out the bugs and improving the performance of Loony.

## What can it do

> While the following is possible; this is only by increasing the alignment our 'node' pointers to 16 which would invariably effect performance.
>- Lock-free consumption by up to **32,255** threads
>- Lock-free production by up to **64,610** threads
>
> You can use `-d:loonyNodeAlignment=16` or whatever alignment you wish to adjust the contention capacity.

With the 11 bit aligned implementation we have:
- Lock-free consumption up to **512** threads
- Lock-free production up to **1,025** threads
- Memory-leak free under **ARC**
- Can pass ANY ref object between threads; however:
  - Is perfectly designed for passing Continuations between threads
- **0 memory copies**

## Issues

**Loony queue only works on ARC**.

ORC is not supported (See [Issue #4](https://github.com/shayanhabibi/loony/issues/4))

Spawn (Nims `threadpool` module) is not supported. *It won't ever be; don't use spawn unless you are a masochist in general.*
## Installation

Download with `nimble install loony` (CPS dependency for tests) or directly from the source.

### How to use

Simple.

First, ensure you compile with arc and threads (`--gc:arc --threads:on`)

Then:
```nim
import pkg/loony

type TestRef = ref object

let loonyQueue = newLoonyQueue[TestRef]()
# Loony takes reference pointers and sends them safely!

var aro = new TestRef

loonyQueue.push aro
# Enqueue objects onto the queue
# unsafePush is available, see MemorySafety & Cache Coherance below!

var el = loonyQueue.pop
# Dequeue objects from the queue
# unsafePop is available, see MemorySafety & Cache Coherance below!
```

There is now a preliminary sublibrary which provides state managers called `Ward`'s.
These can be imported with `import loony/ward`. The documentation is found below,
tests and further documentation are to follow when time allows.

## Documentation

[The full API documentation is kept up-to-date on GitHub.](https://nim-works.github.io/loony/loony.html)

[~~The API documentation for the Ward submodule is found here.~~](https://nim-works.github.io/loony/loony/ward.html) ~~*Wards are untested and are unlikely to remain in the library*~~

#### Memory Safety & Cache Coherence

Loony's standard `push` and `pop` operations offer cache coherency by using
primitives such as `atomic_thread_fence` to ensure a CPU's store buffer is
committed on the push operation and read on the pop operation; this is a
higher-cost primitive. You can use `unsafePush` and `unsafePop` to manipulate
a `LoonyQueue` without regard to cache coherency for ultimate performance.

The LoonyQueue itself is padded across cachelines, and by default, the slots
are read and written to in a cyclic fashion over cachelines to reduce false
sharing.

```
Visual representation of rotating index

| 64 bytes | 64 bytes | 64 bytes |...
| 0------- | 1------- | 2------- |...
| -63------| -64------| -65------|...
|--127-----|--128-----|--129-----|...
```

### Debugging

Pass `--d:loonyDebug` in compilation or with a config nimscript to use debug
procedures and templates.

> Warning :warning: this switch causes node allocations and deallocations to
> write on an atomic counter which does marginally effect performance!

`echoDebugNodeCounter() # Echos the current number of nodes in the queue`

```nim
debugNodeCounter:
  # Put things onto the queue an off the queue here! At the
  # end of the template, if the number of nodes you started
  # with does not equal the number of nodes you finished
  # the block with, it will print information that is useful
  # to finding the source of the leak! This template will not
  # do anything if loonyDebug is off.
  discard
```

### Compiler Flags

We recommend against changing these values unless you know what you are doing. The suggested max alignment is 16 to achieve drastically higher contention capacities. Compilation will fail if your alignment does not fit the slot count index.

`-d:loonyNodeAlignment=11` - Adjust node alignment to increase/decrease contention capacity

`-d:loonySlotCount=1024` - Adjust the number of slots in each node

`-d:loonyDebug=false` - Toggle debug counters and templates, see
[debugging](#debugging). False by default.

`-d:loonyRotate=true` - Toggle the index for the slots of
loony queue to be read over cacheline bounds in a cyclic
manner. True by default.

> While loonyRotate is enabled, the slot count must be a
> power of 2. Error messages will indicate whether this
> is a cause of compilation failure.

## What are Continuations?

If you've somehow missed the next big thing for nim; see [CPS](https://github.com/nim-works/cps)
