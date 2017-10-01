---
layout: post
title: The case of the 2 million close calls
date: 2017-10-1 11:23:20 +0100
author: Javier Honduvilla Coto
categories: Linux systems programming syscall
---

This summer, while working on my internship project, I realised that an internal CLI tool was taking _too_ long to run. The tool purpose is not very relevant here, but my understanding was that it should finish in way less than a second, however, it was taking several seconds perform its work.

### First debugging attempts
Being a bit clueless about this, I tried running `strace` with the `-fc` flags (so children processes would be also tracked and it would display a very nice summary of the syscalls instead of per syscall information) on it. The result was a bit surprising, as there were almost *2 million* calls to `close` which were accounting for around 80% of the total runtime. What is more, more than 90% of them had failed. Interesting!

I ran `strace` on the process again, but this time without the `-c` option, as I didn't want a summary, but each individual system call.

A funny pattern starting appearing by the mid of the output: most of the failed `close` calls were one after another and they were attempting to close incremental file descriptors :o

After letting know about this in one of the internal groups related to this tool, a co-worker explained me a bit on how the tool worked and offered to chat more about this, unfortunately, I had some higher priority things to do and decided to put this aside.

### Revisiting this issue
That was just for a couple of weeks until we had the infrastructure hackathon! It was pretty amazing, many teams came up with super cool ideas and I wish I could have joined all of them. What is more, my pretty average ideas were listened, I got feedback on them, and even some engineers thought they were worth working on them :D

One of those ideas, of course, was debugging what on earth was going on to close so many consecutive file descriptors. At least it was pretty easy to reproduce :)

I paired with a co-worker who was interested in this and we were both quite perplexed. We fired `gdb` on this process and tried to set a breakpoint on the `close` syscalls. Although we were unsuccessful, we learnt quite a lot about GDB's scripting capabilities and read a bit of assembly, so yay! We have some theories on why our debugging there didn't work, but we are unsure if we are right :/

So he had a cool idea: what about creating a static library which could override the `close` function by using `LD_PRELOAD`, check its argument, and when the file descriptor was extremely high, log its backtrace? He wrote this code and tried it, but the process was being deadlocked now... It seemed like a dead-end and we were not understanding what was going in. We could have tried to `strace` this once again to see what was going on, but we wanted really badly to find the root cause of the original problem. The struggle!

Finally, we gave `perf`[1][2] a try. Using the kernel tracepoints for entering a syscall, we logged the stacktrace with something like `perf stat -e 'syscalls:sys_enter_close' -g -p <pid>`. The result seemed just gibberish, but reading it with a bit more care, it seemed like some mangled symbols. We searched for some of them in our code searcher tool and we end up with something that seemed plausible, it was code that seemed to do operations that were expected from that tool, but still no luck to find the exact culprit. Pew!

My friend and I were really curious about what was going on but were really exhausted already, so finally, I did what I should have done before! Chilling out a bit and stop thinking about this for a while, so I joined some of my fellow interns, which are really amazing, btw.

### The reason behind this behaviour
The next day I starting googling a lot about this and... I found something interesting that I had found some weeks ago and I have had discarded for some reason...

It sums up to: if you are executing a `fork` without doing an `exec` and you want the child not to be able to access in any way they file descriptors it just inherited from the parent you have to close all of them sequentially. From fd=3 up to the max fd available in your system.

I was mindblown. Had always imagined there was some special flag so, the file descriptors were not shared, unfortunately, this only exists when you are calling `exec` afterwards, which was not the case. I also erroneously thought you could just iterate over `'/proc/self/fd/<int>'` and call close on them.
For a variety of reasons, this happens to be unreliable! It's explained really well in this Stack Overflow post[3].

I jot down what we found out and what we didn't know yet in an internal post. To my surprise, a couple of engineers wrote down their thoughts and gave their insight on how to better debug this situation / why this was happening / systems programming general. A group of them suggested using BCC which was really interesting and I have never tried it myself.

### Conclusion
It was a great learning experience. Learned more about systems <3, talked to many engineers from all around the company who were incredibly approachable, nice, and were genuinely happy to help to sleuth this. My manager was also amazing supporting me during the whole internship, including with this :)

I should have probably posted about this issue before as well as better explaining the purpose of the post itself :)

### References
* [1] [https://jvns.ca/blog/2015/03/30/seeing-system-calls-with-perf-instead-of-strace/](https://jvns.ca/blog/2015/03/30/seeing-system-calls-with-perf-instead-of-strace/)
* [2] [http://www.brendangregg.com/perf.html](http://www.brendangregg.com/perf.html)
* [3] [https://stackoverflow.com/questions/899038/getting-the-highest-allocated-file-descriptor/918469#918469](https://stackoverflow.com/questions/899038/getting-the-highest-allocated-file-descriptor/918469#918469)

### Notes
* It's fun to see how this is implemented, such as in [CPython](https://github.com/python/cpython/blob/163468a766e16604bdea04a1ab808c0d3e729e5d/Modules/_posixsubprocess.c#L216) or in [Facebook's folly library](https://github.com/facebook/folly/blob/4af3040b4c2192818a413bad35f7a6cc5846ed0b/folly/Subprocess.cpp#L484-L490)

