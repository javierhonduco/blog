---
layout:     post
title:      open and CPython
date:       2020-1-19
author:     Javier Honduvilla Coto
categories: Python CPython GC systems
---

# `open` and Python
**TL;DR**: _Misusing_ Python's `open` and the interaction of CPython's GC and UNIX semantics can lead to unexpected results!

Last week, a teammateand I were working on some Python code to spawn a new process. The API we were relying on offered a familiar API very similar to `subprocess`‘. We wanted to write the `stdout` and `stderr` in two separate files, rather than just writing to the parent's streams. Fortunately, the method we were calling offered this functionality, we only needed to pass a valid file descriptor for each stream. It looks something like:

`run("/bin/le_binary", stdout=stdout_fd, stderr=stderr_fd)`

I wanted to quickly know if this worked as expected and ran the short but leaky:

`stdout_fd = open("le_output").fileno()`

We are not closing the file descriptor, but hey we were just testing this out and we were going to change it later. To our surprise this did not work. Neither of the files had any output. Weird!!

## 🕵 The experiments

[Javier](https://www.linkedin.com/in/jjmaestro) brought up that file buffering could be messing up with us, so we then tried some different permutations:

❌ **These do not work**:
- ```run(stdout=open("/tmp/a", "w").fileno())```
- ```run(stdout=open("/tmp/a", "wb", 0).fileno() # buffering disabled```

✅ **These work**:

-
```
file = open("/tmp/a", "wb", 0)
run(stdout=file.fileno()) # buffering disabled
```
-
```
file = open("/tmp/a", "w")
run(stdout=file.fileno())
file.close()
```
-
```
file = open("/tmp/a", "w")
fd = file.fileno()
run(stdout=fd)
file.close()
```
-
```
with open("/tmp/a", "w") as file:
    run(stdout=file.fileno())
```
-
```
import os

fd = os.open("/tmp/a", os.O_RDWR | os.O_TRUNC | os.O_CREAT) # similar flags to what normal `open` uses
os.close(fd)
```
(note that closing the `fd` in the cases it works does not affect the results)

## 🙅🏻Always be closing?

Buffering did not seem to be related. Javier and I felt like the Garbage Collection could be the one to blame, maybe closing the file descriptor behind our backs. We then tried the code above after calling `import gc; gc.disable()`, but the results were the same so I quickly discarded the hypothesis.

We then decided to try to see if somebody was closing the file descriptor without us noticing. Thanks to [bpftrace](https://github.com/iovisor/bpftrace) this is not too difficult:

```
tracepoint:syscalls:sys_enter_close {
    printf("Called close! %d %s\n", args->fd, ustack);
}
```

The script above is tracing close syscalls invocations, and print the native userland stacktrace. The stacktraces look very similar, but there’s one key difference:

```
         _PyCFunction_FastCallDict+40
         _PyObject_CallMethodId_SizeT+762
         _io_TextIOWrapper_close+214
-        _PyMethodDef_RawFastCallKeywords+577
-        _PyMethodDescr_FastCallKeywords+82
-        _PyEval_EvalFrameDefault+25343
+        _PyMethodDef_RawFastCallDict+538
+        _PyCFunction_FastCallDict+40
+        object_vacall+88
+        PyObject_CallMethodObjArgs+164
+        iobase_finalize+182
+        PyObject_CallFinalizer+101
+        PyObject_CallFinalizerFromDealloc+30
+        textiowrapper_dealloc+18
+        _PyEval_EvalFrameDefault+2535
         _PyFunction_FastCallKeywords+270
         _PyEval_EvalFrameDefault+1855
         _PyEval_EvalCodeWithName+691
```

[Visual diff](/images/cpython_close_diff.png)

Checking [the documentation](https://docs.python.org/3/c-api/typeobj.html?highlight=tp_finalize#c.PyTypeObject.tp_finalize) for `PyObject_CallFinalizerFromDealloc`

> It is called either from the garbage collector (if the instance is part of an isolated reference cycle) or just before the object is deallocated.

We got this same stacktrace with the  Garbage Collector disabled. This was when I remembered that Python uses a Mark and Sweep GC mainly to deal with cyclic references, but it also uses Reference Counting, this mean, that when an object is pointed by 0 other objects, it’s safe to be deleted.

In this case, by calling `open("/tmp/a", "w").fileno()`, the deterministic part of Python's GC, the Reference Counting process, detected that what `open` returns, a `FileObject` has 0 objects pointing at it by the time `fileno()` returns so it should be safe to destroy the object. This is done by calling its destructor.

## 🎍Take aways
As it turns out, the `FileObject` destructor closes the file descriptor it opened. What I stumbled upon is a fun “undefined behaviour” of not using Python’s library properly and the interaction of it and Unix’s semantics, with years and years of history 😄

This behaviour is due to a CPython implementation detail, it's not in any spec and in may vary in other Python implementations.

Unfortunately, the library we are passing this file descriptor seems like it’s not bubbling the error up in the stack the operation the do on the `fd` fails, so this is probably the reason why we did not see an error anywhere!

Finally, when coding in high level languages, like Python, we usually don't have to think about this kind of interactions, but this is not always the case 🙂

## 🔦 Random thoughts
* While we were not using a context manager, calling `os.close` passing it the `fd`, this is unsafe, as it will, in the best case, call close unnecessarily, and in the worst case close the wrong `fd`, as they are reused and it can be allocated somewhere else in the process. There seem to be so many ways to mess up with file descriptors, I definitely did not see this coming when I was in my first OS class in uni 😂
* Safe(r) systems programming: to my knowledge, Rust is the only popular language that [models this right, reducing the chances of messing up](https://play.rust-lang.org/?version=stable&mode=debug&edition=2018&gist=b3aaae4358b5cdedd7c26e29b884315a)
* Found [this short read on different Python implementation's GC's](https://pdfs.semanticscholar.org/ed0a/1cdf9bb639084e80794b9e5a95fa616bb848.pdf), they explicitly mention this case, but with `.write`, which works fine but depends on said CPython's reference counting implementation detail
* I could have avoided this if I had used the API the way it's supposed to, but at least I've learnt something new!
