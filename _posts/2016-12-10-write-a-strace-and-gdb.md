---
layout: post
title:  Write a (toy) strace and gdb
date:   2016-12-10 8:23:20 +0100
author: Javier Honduvilla Coto
categories: strace ptrace gdb systems programming c
---

Being able to peek into a process is a very helpful thing when we want to fully understand how a program behaves.

`strace` and `gdb` are awesome tools for debugging. While the first allows you to trace which system calls the program has made, the second one has a way wider set of tools suck as being able to see the source code, set breakpoints, read and set variables, registers and a myriad of other options.

Usually we can invoke them specifying a `pid` of another process that we want them to take over or directly an executable.

### So, how do those tools work?
I was wondering how those tools internally work, and after reading a bit about how Linux handles processes I stumbled upon `ptrace`.

`ptrace` is a system call that is crucial for the implementation of debuggers.
We can do several things with it, such as telling the OS that we want to be traced, that we want to trace another process given a `PID`, ...
Among them, the 2 that are going to be really intersting for the implementation of a tracer or debugger are the `TRACE_SYSCALL` - which notifies the tracer process before and after a system call!! and `PTRACE_SINGLESTEP` which runs every step!

Another really interesting argument we can use is `PTRACE_GETREGS` which allows us to read the registers of the process. (We also have `PTRACE_SETREGS` to set some registers to custom values).

### mystrace & mygdb
I ended up implementing two C programs: "mystrace" and "mygdb".

Both programs are similar in structure, they do a basic parsing of the command line arguments, as they should work with `./program -p <pid>` option as well as `./program ls`.
Depending on the arguments, it `fork`s + `exec`s a new process with the before mentioned `PTRACE_ATTACH` on the parent process and `PTRACE_TRACEME` on the child.

Once that has been done, `ptrace` is executed again.
#### In "mystrace"
we want to capture system calls, so we request it with `PTRACE_SYSCALL` as its argument.
As it's executed before and after every system call, and we are in this case only interested on the system call name and return code we are skipping thos iterations of the loop.

After that we fetch the registers, especifically `orig_rax`, where the id for the system call is stored, and `rax`, where we can find the result of the system call.

We want to print the system call name and exit code. Unfortunately, we have the id, so I've created with the help of a simple Ruby script a structure to map those. You can find it in the header.

#### In "mygdb"
the objective was to be able to execute step by step, going to the end and showing the registers.

With the help of `ptrace`'s `PTRACE_SINGLESTEP` we can accomplish this task.
In the `prompt_user` function, the program gets the user input and reacts accordingly.

### Conclusion
Implementing two tools that I love has been a blast. I can realize even more how the passionate and hard work of many individuals around the world has made those tools as amazing as they are now.

Implementing half of the features they have, including being more portable would be something pretty crazy!

Even thought those two programs are just toys and nothing comparable to `strace` or `gdb`, despite of its name, they manage to get the basic information in a reasonable amount of code and complexity!

Hope you enjoy it! :)

### Notes & links
* Vector operations are also known as SIMD (single instruction multiple data)
* Tenderlove's post
* moar doc
* wikipedia article...

{% highlight ruby %}
def print_hi(name)
  puts "Hi, #{name}"
end
{% endhighlight %}