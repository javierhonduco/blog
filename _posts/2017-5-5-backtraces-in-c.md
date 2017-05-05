---
layout: post
title: Backtraces in C
date: 2017-5-5 8:23:20 +0100
author: Javier Honduvilla Coto
categories: Linux backtraces systems programming c
---

Some weeks ago I started doing a side project in C. It didn't do really complex stuff, but still, I was struggling with some "core" C stuff, namely pointers!

Even though I've done some university assignments in C that were pretty interesting, such as a toy file system, or a scheduler, I never learn how some stuff worked for real so I've been "brute-forcing" those parts of the code, by trying all possible combinations of `*`, `&`, etc (if you are struggling with those concepts, I can assure you that with some C book or a friend that can explain that to you, you will understand them for sure! :D)

So, back to my pet project! I had some segmentation faults, and what I did was debugging it with GDB to get the backtrace and line where the segfault happened which works awesomely. Nevertheless, I was missing my insert-higher-level-language backtraces, and thought I could get something together that could do it (thought [somebody](https://www.gnu.org/software/libsigsegv/) [else](https://github.com/ddopson/node-segfault-handler) [probably](http://faulthandler.readthedocs.io/) had already done that, spoiler alert: yes!!).

To be honest, I wondered if that could be possible at all, but then I remembered that when the Ruby interpreter crashed with a segfault, it reported the crash with some really interesting information such as the registers' values :)

### The idea

What I wanted to do was roughly:
1. Install a signal handler for a segmentation fault. I first checked that was possible in the manpages for "signal" (with `man 7 signal`) which states that "The signals SIGKILL and SIGSTOP cannot be caught, blocked, or ignored.", which makes sense, but I didn't! Yay! I've learnt something else!
2. Do something
  - print the backtrace
  - print the line that caused the fatal exception

### The implementation
First of all, we need to register the segfault handler with something like:
```c
  struct sigaction sig;
  sig.sa_sigaction = segfault_handler;
  sig.sa_flags = SA_SIGINFO;

  if(sigaction(SIGSEGV, &sig, NULL) < 0) {
    puts("[error] signal registering failed");
    exit(-1);
  }
```
and the function that I, boringly called, `segfault_handler`:
```c
  void segfault_handler(int signal, siginfo_t* siginfo, void* context) {
  // to be implemented
  }
```

I just wanted to try if that worked, so, inside the `main` function, just after the signal handler registration, I triggered a segmentation fault with a `NULL` dereferencing:
```c
int *faulty = 0;
faulty = 314;
```

I compiled and run it but the program didn't stop! It seemed to be stuck in an infinite loop, but I had no clue of what was happening, so I turned to our friend `strace` (which if you haven't heard before you should check out [this blog posts](https://jvns.ca/categories/strace/) by Julia Evans!) and I saw that the program was receiving lots of segmentation faults instead of just one!

After some Googling and thinking on why that could happen, the answer was really interesting! The program counter, which is the register that points to the next instruction that it's going to be executed, wasn't incremented when the segmentation fault happened. That means that when the signal handler returned it would continue at exactly the same instruction that caused the segfault, triggering it again, executing the signal handler again, and so on!!

Maybe this is "obvious" but at least it wasn't for me :). I decided to exit the program just before the handler returned with an `exit(139)` which is the return value that indicates that a segfault happened.

After this incise, let's have a look at the two features that I wanted to have:

#### backtraces
This was easier than I thought because there's actually a library that does precisely this for us! It's called... `backtrace`! With the addresses that it returns and `backtrace_sybols` we can get human-readable function names if the binary was compiled with debug symbols (usually option `-g`).

```c
// how many stack levels we want to get
unsigned int stack_depth = 25;

void* callstack[stack_depth];
int frames = backtrace(callstack, stack_depth);

char** strs = backtrace_symbols(callstack, frames);
for(int i=0; i<frames; i++) {
  puts(strs[i]);
}

free(strs);
```

The output of the code above is something like:
```
./segfault() [0x40097c]
./segfault() [0x400b53]
/usr/lib/libc.so.6(+0x330b0) [0x7f0e1733b0b0]
./segfault() [0x400bcb]
/usr/lib/libc.so.6(__libc_start_main+0xf1) [0x7f0e17328291]
./segfault() [0x40082a]
```

#### offending line
In order to be able to display the offending line, we somehow have to know in which part of the code did our process attempted a forbidden action, like a forbidden memory write, like in this case.

We can do that with the register that points to that instruction. In x86 it's called the "rip" register. The `sigaction` function is really handy here, as the third parameter that it receives it's a pointer to a struct that holds lots of information, including the registers! Great! :D

We can get its value with:
```c
unsigned long long pc = ((ucontext_t*)context)->\
    uc_mcontext.gregs[REG_RIP];
```

Now we need to get the actual file and name for it. That can be done leveraging [`addr2line`](https://sourceware.org/binutils/docs-2.21/binutils/addr2line.html) which I think it's amazing! Given the binary and the address, it will give us something like `file:line`. Super convenient!

Now I passed the value of the `rip` register to `addr2line` and we already know everything we need! Yay!!

We would like to display the actual line, we can just open the source code file, go until that line and print it. Being a bit lazy I have to confess I called a small Python program from the C binary that using `linecache` it will print the line. Not very efficient but it works.

### Wrapping up
As you probably have noticed, we need to copy & paste this code into the code we are working on and that's, unfortunately, a bit cumbersome :sadpanda:.

After some more searching on the internet I've learnt about an amazing thing: ["function attributes"](https://gcc.gnu.org/onlinedocs/gcc-4.3.3/gcc/Function-Attributes.html) which allow us, for example, writing code that runs _before_ main is executed (among many other things), which is super cool even though I don't really understand how they work, but it's just what we need!

We can now "decorate" a function that installs the handler with:
```c
__attribute__((constructor))
```

and once we compile it as a shared library, we can tell the linker to set it up while running some other program with [`LD_PRELOAD`](https://rafalcieslak.wordpress.com/2013/04/02/dynamic-linker-tricks-using-ld_preload-to-cheat-inject-features-and-investigate-programs/).

### Conclusions
So, after we compile this code as a static shared library called segfault and the code that can fail being "experiment", we can do:
```bash
$  LD_PRELOAD=./segfault.so ./experiment
```

and the output would be something like:

```
========== The program crashed =========
==> context
0x4004b6
/home/javierhonduco/c-nice-sigsegv/experiment.c:3

==> offending sigsegv line
*faulty = 314;
==> stacktrace
./segfault.so(print_stacktrace+0x86) [0x7f8e2e286bb6]
./segfault.so(sigfault_handler+0x183) [0x7f8e2e286d9b]
/usr/lib/libc.so.6(+0x330b0) [0x7f8e2df1b0b0]
./experiment() [0x4004b6]
/usr/lib/libc.so.6(__libc_start_main+0xf1) [0x7f8e2df08291]
./experiment() [0x4003da]
========================================
```

This post got longer than expected! :o

I've learnt many stuff that I did't know about before, so it's been pretty cool to do this :)

The complete code can be found [here](https://github.com/javierhonduco/wheres-my-segfault).

### Notes
* For some reason, while compiling this on OSX (which has a different `u_context_` struct) I had to disable address space randomization passing the `-nopie` to the linker, which I didn't have to do in Linux. I don't know why in Linux that's not necessary, don't know if `gcc` by default disables it when the debugging symbols flag is passed or it's something else.
* There are some functions that are not signal safe – which is pretty interesting –, and `puts` is among them. We could use `write(stdout, "<>");` instead, but I've decided to keep it like this for simplicity.
* This could be extended to catch more signals such as `sigill` as well :)
* This is probably broken in many ways
