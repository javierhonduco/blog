---
layout: post
title: Linux's OOM
date: 2017-3-4 8:23:20 +0100
author: Javier Honduvilla Coto
categories: Linux OOM systems programming c
---

Some days ago I was wondering how Linux decides which process to kill when free memory is running low. (Spoiler: heuristics!)

I was a bit scared to peek into the Kernel's source code, but as it turns out, this particular code is not extremely difficult to grasp :). The code is well documented and clean.

The code that we are most interested in is located in [`linux/mm/oom_kill.c`](https://github.com/torvalds/linux/blob/master/mm/oom_kill.c).

It all starts with the `pagefault_out_of_memory` function, which is called when the pagefault handler is out of memory, as described in the comments.

In case no other OOM task is being run, `out_of_memory` is called, and it does a bunch of stuff. It checks some conditions, such as if the OOM killer is disabled, and if some memory has been recently freed. In the case that the current process has a pending `SIGKILL` or it's on its way to exit, this process is killed. After some more checks related to NUMA, it calls `select_bad_process`, and kills the process that it selects. If no process is selected, an OOM panic is called.

`select_bad_process` [iterates over all processes](https://github.com/torvalds/linux/blob/master/mm/oom_kill.c#L354-L356) and for each of them, calls `oom_evaluate_task`.
The most interesting cases imo, are:
- In case the task is marked as 'unkillable', it is skipped.
- If the task is grabbing lots of memory and has been marked to be killed first, it is selected.

After a couple of other test conditions, the heuristics are computed in the `oom_badness` function. The process that will be killed would be the one with the biggest score. In case that this process' score is lower than the maximum one, it is skipped.

Finally, we arrive to the heuristics!
A score of 0 is given in the following conditions:

- again, if the task is unkillable.
- if the memory management struct field of the process or any of its threads is nonexistent
- if the process is in the middle of a `vfork`

Then, the base points are computed with this [formula](https://github.com/torvalds/linux/blob/master/mm/oom_kill.c#L202-L203), which renders a score that is proportional to the RAM and swap usage, among other things.

If the process is a privileged one, [its score is decreased](https://github.com/torvalds/linux/blob/master/mm/oom_kill.c#L210-L211).

Lastly, the points are normalised before returning them.


### Notes
As usually, I'm not an expert at all in the subject. I was just really curious how this works in reality :). Shall you find some error, feel free to let me know!
