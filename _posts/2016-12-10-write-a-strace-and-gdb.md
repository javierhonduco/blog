---
layout: post
title:  Write a (toy) strace and gdb
date:   2016-12-10 8:23:20 +0100
author: Javier Honduvilla Coto
categories: strace ptrace gdb systems programming c
---

Being able to peek into a process is a very helpful thing when we want to fully understand how a program behaves.

`strace` and `gdb` are awesome tools for debugging. While the first allows you to trace which system calls the program has made, the second one has a way wider set of tools such as being able to see the source code, set breakpoints, read and set variables, registers, and a myriad of other options.

Usually, we can invoke them specifying a `pid` of another process that we want them to take over or by passing them the executable.

### So, how do those tools work?
I was wondering how those tools work internally, and after reading a bit about how Linux handles processes I stumbled upon `ptrace`.

`ptrace` is a system call that is crucial for the implementation of debuggers.
We can do several things with it, such as telling the OS that we want to be traced, that we want to trace another process given a `pid`, ...
Among them, the 2 that are going to be really interesting for the implementation of a tracer or debugger are the `TRACE_SYSCALL` - which notifies the tracer process before and after a system call!! and `PTRACE_SINGLESTEP` which runs every step!

Another really interesting argument we can use is `PTRACE_GETREGS` which allows us to read the registers of the process. (We also have `PTRACE_SETREGS` to set some registers to custom values).

### mystrace & mygdb
I ended up implementing two C programs: "mystrace" and "mygdb". Its source code can be found [here](https://github.com/javierhonduco/write-a-strace-and-gdb).

Both programs are similar in structure, they do a basic parsing of the command line arguments, as they should work with `./program -p <pid>` option as well as `./program ls`.
Depending on the arguments, it `fork`s + `exec`s a new process with the aforementioned `PTRACE_ATTACH` on the parent process and `PTRACE_TRACEME` on the child.

Once that has been done, `ptrace` is executed again.
#### In "mystrace"
we want to capture system calls, so we request it with `PTRACE_SYSCALL` as its argument.
As it's executed before and after every system call, and we are in this case only interested on the system call name and return code we are skipping those iterations of the loop.

After that, we fetch the registers, specifically `orig_rax`, where the id for the system call is stored, and `rax`, where we can find the result of the system call.

We want to print the system call name and exit code. Unfortunately, we have the id, so I've created - with the help of a simple Ruby script - an array to map those. You can find it in the appropriate header.

#### In "mygdb"
the objective was to be able to execute step by step, going to the end and showing the registers.

With the help of `ptrace`'s `PTRACE_SINGLESTEP` we can accomplish this task.
In the `prompt_user` function, the program gets the user input and reacts accordingly.

### Conclusion
Implementing two tools that I love has been a blast. I can realise even more how the passionate and hard work of many individuals around the world has made those tools as amazing as they are now.

Coding half of the features they have, including being more portable would be something pretty crazy to do!

Even though those two programs are just toys and nothing comparable to `strace` or `gdb` (despite its name) they manage to get the basic information in a reasonable amount of code and complexity IMHO!

Hope you enjoyed it! :)

(I'm not, by any means a C or `ptrace` expert, I just played with it for the first time. Feel free to correct anything you think it's not ok! :))

### Notes & links
* [`ptrace` man pages](http://man7.org/linux/man-pages/man2/ptrace.2.html)
* [Julia Evan's wonderful zines](http://jvns.ca/zines/)
* [Filippo Valsorda's Linux sycall table](https://filippo.io/linux-syscall-table/)
* [strace source code](https://github.com/bnoordhuis/strace)
* [GDB project page](https://www.sourceware.org/gdb/)
* [the code of this post](https://github.com/javierhonduco/write-a-strace-and-gdb)
