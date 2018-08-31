---
layout: post
title: Extracting Python data with GDB
date: 2018-8-31 12:00:00 +0100
author: Javier Honduvilla Coto
categories: systems programming Python GDB
---

GDB has an amazing feature that allows to run arbitrary functions on a target process. This is really useful to access information at runtime that was not enabled ahead of time.

So far I've used it for two purposes:

- Unreclaimable objects 🐍🥈🔁🙅‍♀️🗑

Thanks to Bruno Penteado I learnt that objects with destructors that were part of cyclic references were never garbage collected in CPython 2.

Given that many people still runs Python2 code in production, I thought it could be interesting to count how many objects and which are they are leaked because of this behaviour.

```shell
sudo gdb \
  -p $pid \
  -ex 'call (int)PyGILState_Ensure()' \
  -ex 'call (int)PyRun_SimpleString("import gc; open('\''/tmp/unreclaimable_garbage'\'', '\''w+'\'').write(str(gc.garbage))")'  \
  -ex 'call (int)PyGILState_Release()' \
  -ex 'set confirm off' \
  -ex quit
```

- Fetching the Python stacktrace of a hung Python process ❄

```shell
sudo gdb \
  -p $pid \
  -ex 'call (int)PyGILState_Ensure()' \
  -ex 'call (int)PyRun_SimpleString("import traceback; traceback.print_stack(file=open('\''/tmp/stacktrace'\'', '\''w+'\''))")'  \
  -ex 'call (int)PyGILState_Release()' \
  -ex 'set confirm off' \
  -ex quit
```


### Warning, crashes ahead ⚠️⚠️⚠️⚠️
This is potentially dangerous, don't run it in production unless you are ok with your process being stopped and / or crashing.

### Conclusion
In lost objects, despite not providing you with any other important information such as the total size of the leak due to this implementation detail, or the cycle reference creation "callsite", I think it could be interesting to see if this type of leak happens. Another good reason to upgrade to Python3!!! :D

Check out [pyrasite](https://github.com/lmacken/pyrasite) which also uses this technique to enable really cool things :)

Hope this is somewhat useful!! Please send me your feedback, ideas, and sleuths.
