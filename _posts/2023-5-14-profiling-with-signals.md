---
layout:     post
title:      Profiling with signals
date:       2023-5-14
author:     Javier Honduvilla Coto
categories: profiling signals
---

Sampling profilers periodically fetch the stacktrace of the application under observation. Historically, this has been from within the process, in-band,  using signals. In fact, there's a signal dedicated for this sole purpose, `SIGPROF`. We can register a signal handler for it that would retrieve the current stack. This stack could then be added to some data structure and eventually, the generated profile can be written somewhere, such as on disk.

## Advantages of signal-based profiling

Assuming that the provided stack unwinding mechanisms that the runtime might provide is signal-safe[0], there is no need to re-implement the stack unwinding machinery. This can be very convenient because most languages, particularly high-level ones, don't tend to have a stable stack ABI. By using the already implemented[1] unwinder in signal handlers, we don't need to account for internal details that might change in future versions.

Another benefit of using signals is that we can make our profiler work across many Unix-like operating systems without having to make too many changes to the code.

## Signal-based profiling issues

Unfortunately, signal-based profiling is not without issues. For example, when delivering a signal to a process, it will stop whatever it was doing and will start running the code of the profiler, altering the state of the process, such as its registers, stack, etc.

What's worse, the signal might arrive when your process is busy doing CPU-intensive work, causing a delay in the computation or while it's blocked on IO. In the latter case, the process will be scheduled again and a stack will be captured. This can be misleading because we might think that the process itself, and not the kernel, was actually consuming CPU at the time if we don't carefully analyze the resulting profile looking for frames that might cause our program to be de-scheduled[2].

Ideally, when analyzing CPU cycles, if our process is not running in the CPU, a profile should not be captured at all! This is what we call on-CPU profiling, rather than wall-clock profiling, which is what most signal-based profilers do.

### Interrupted system calls

So what happens if we are blocked on IO and a system call arrives? Let's check with a small C program:

```c
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <sys/time.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>

void handler() {
    printf("=> SIGPROF received\n");
    alarm(2);
}

int main() {
    signal(SIGPROF, handler);
    int slept_for_secs = sleep(1000);
    printf("sleep returned: %d errno: %s\n", slept_for_secs, strerror(errno));
    if (slept_for_secs != 0) {
            printf("got interrupted, didn't sleep as much as I wanted\n");
    }
    return 0;
}
```

When we run ```kill -SIGPROF $(pidof sleepy)```, the signal is eventually received, and sleep returns with a number bigger than 0, indicating it didn't sleep for as long as it was supposed to:

```
=> SIGPROF received
sleep returned: 998
got interrupted, didn't sleep as much as I wanted
```

If we wanted to sleep for the entirety of the requested time we would have to check for `errno == -EINTR` and retry with the remaining time that we could not sleep.

Running the signal manually can be tiring, so let's do what real signal-based profilers do: set a periodic timer via `setitimer`:

```c
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <sys/time.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>

void handler() {
    printf("=> SIGPROF received\n");
    alarm(2);
}

void sigprofme(int secs) {
    struct itimerval itimer = {};
    it_value.tv_sec = secs;
    itimer.it_interval = itimer.it_value;
    if (setitimer(ITIMER_PROF, &itimer, NULL) == -1) {
        perror("error calling setitimer()");
        exit(1);
    }
}

int main() {
    signal(SIGPROF, handler);
    sigprofme(2);
    int slept_for_secs = sleep(1000);
    printf("sleep returned: %d errno: %s\n", slept_for_secs, strerror(errno));
    if (slept_for_secs != 0) {
            printf("got interrupted, didn't sleep as much as I wanted\n");
    }
    return 0;
}
```

Let's recompile it and run it, and... nothing happens! The `sleep` call continues, and the process barely has used any CPU. Fortunately, [libc's documentation](https://www.gnu.org/software/libc/manual/html_node/Alarm-Signals.html) has the answer to this:

> This signal typically indicates the expiration of a timer that measures both CPU time used by the current process, and CPU time expended on behalf of the process by the system. Such a timer is used to implement code profiling facilities, hence the name of this signal.

We aren't using many CPU cycles in userspace as we have quickly been de-scheduled. The kernel might be using a bit of CPU for accounting purposes, but in any case it's probably very few CPU cycles, so it would take a very long time to ever a whole 2 seconds of kernel CPU time.

Bear in mind that is is a contrived example where all the userspace threads are blocked, and the kernel barely has to do any work while we are de-scheduled. In other situations, such as the kernel using CPU might make things a bit more exciting.

### Signals and threads

What about multi-threaded applications? The accounting of CPU that's used when using `setitimer` with SIGPROF is done on a per-process level. It's important to know what thread executes the signal handler as this might incur a bias on the samples. The [`pthread(7)` manpage](https://linux.die.net/man/7/pthreads) says:

> POSIX.1 distinguishes the notions of signals that are directed to the process as a whole and signals that are directed to individual threads. According to POSIX.1, a process-directed signal (sent using kill(2), for example) should be handled by a single, arbitrarily selected thread within the process. Linux threads does not support the notion of process-directed signals: signals may only be sent to specific threads.

This doesn't say much about our situation: signals the kernel sends. Let's add threads to our example above and see what happens.

```patch
+#define WORKERS_COUNT 20

+// Hopefully avoid compiler optimisations.
+int global_counter = 0;


+void worker_thread() {
+    for(;;) {
+        global_counter++;
+    }
+}

+void create_worker() {
+    pthread_t thread;
+    for(int i=0; i<WORKERS_COUNT; i++){
+        int ret = pthread_create(&thread, NULL, &worker_thread, NULL);
+        if(ret != 0) {
+            printf("Create pthread error!\n");
+            exit(1);
+        }
+    }
+}

int main() {
+    create_worker();
    [...]
}
```

Running it under `strace` showed that the signal appears to be sent to seemingly arbitrary worker threads. Except for the main thread, as it's barely using any CPU. This makes sense. Let's bias the workers by having half of them ocassionally sleep to see what happens.

```patch
void worker_thread() {
    for(;;) {
+        if(gettid()%2 == 0) {
+            sleep(1);
+        }
        global_counter++;
    }
}
```
I want to get as much output as possible, quickly, to try to understand which threads might be receiving the signal but `strace` was slowing things down. This is due to not just using `ptrace` underneath, incurring in a couple of extra context switches, but also because threads' execution will be serialized, and our application will effectively become concurrent, but not parallel.

```
$ sudo bpftrace -e 'tracepoint:signal:signal_deliver /comm == "sleepy" && args->sig == 27/ { printf("tid %d got SIGPROF\n", tid); }'
```

```
tid 19797 got SIGPROF
tid 19791 got SIGPROF
tid 19795 got SIGPROF
tid 19815 got SIGPROF
^C
```

Much faster, nice! The logs seem to indicate that we got only even thread IDs, which may indicate that the kernel won't send `SIGPROF` to an arbitrary system call, but to the one consuming quota specified in `setitimer` while accounting for CPU time in both userspace and kernelspace. It's good to verify our assumptions, but this definitely makes sense to me!

Something that was interesting here was that the number of times each thread received the signal differed quite a bit from thread to thread. Thanks Ivo for pointing me to [proftest](https://github.com/felixge/proftest), which evaluates this!

## Signals for profiling beyond the theory

Signal-based profilers have several shortcomings as discussed above. While I was aware of some of these issues, mostly regarding the correctness of the profiles, I had never experienced a production incident caused by them until recently. This is what happened.

We pushed a new version of our Go application to a production-like cluster and some of the processes insta-crashed. They run on Kubernetes, so they were promptly restarted.

For context, Go ships with a signal-based profiler called [`pprof`](https://pkg.go.dev/net/http/pprof). This name is shared by a lot of different things, including the profiler itself, the format of the output it produces, and some of the surrounding tooling. Here, we refer to this profiler implementation.

Our application loads a complex BPF program. It used to be rather small, but now it's gotten larger. BPF programs run in kernel-space, so they have to be deemed safe by the kernel using an included static analyzer called the [BPF verifier](https://docs.kernel.org/bpf/verifier.html). It performs some checks such as ensuring that the program terminates.

After some head scratching, some logs readings, and diving through Go's and the Linux kenel's sources, I started to get an understanding of what was going on.

What happened:
1. We register a `pprof` endpoint. Once it's hit, a signal handler will be set up and `SIGPROF` will be sent to our program;
1. One of the first things we do is load the BPF program. The verifier starts processing our program using quite a bit of kernel CPU cycles for large programs;
    - While this is happening, there's a check to see if there's any pending signal. This is useful to, for example, return to userspace if the user is sending `SIGINT` to the application. When this happens, all the intermediate progress is lost, and we return to the userspace application with `errno == -EINTR`.
1. Now we are back in userspace. We use libbpf to load and manage everything BPF related. When it calls the BPF system call, `bpf(2)`, if it fails with `-EINTR`. [It retries the operation up to 5 times by default](https://github.com/libbpf/libbpf/blob/532293bdf427b2881a86ad7a1b9380465db48eac/src/libbpf_internal.h#L577), then returns the error;

Turns out we were being interrupted 5 times, so the sixth time wasn't retried again and it errored. We diligently exited when this happened, as we need the BPF program to be loaded to work. The reason why I didn't bump into this locally while working on these feature is that the `pprof` endpoint was never hit but it's periodically called in our production-like environment.

The fix was not hard: [setting the pprof endpoint once the BPF program is loaded](https://github.com/parca-dev/parca-agent/pull/1276).

## Alternative approaches

Some other profilers follow a debugger-like approach. They read the memory of a target process, from another process (out-of-band). This post is getting a bit too long, so I hope to write about alternative approaches soon!

## Conclusions

Authoring profiling tools is a careful exercise in tradeoffs. What's the maximum overhead we want to incur. What versions of runtimes do we want to consider. Do we want to just support Linux or various operating systems? Which OS do we want to support?. How fair do we want to be? These are among the many decisions to make and arguably the best way to understand some of these tradeoffs well is to do lots of experiments.

## Notes

- [0] [signal-safety(7)](https://man7.org/linux/man-pages/man7/signal-safety.7.html)
- [1] Go's [`PrintStack`](https://pkg.go.dev/runtime/debug#PrintStack) and Ruby's [`Kernel#Caller`](https://ruby-doc.org/3.2.1/Kernel.html#method-i-caller).
- [2] In PMU-based profilers we can tell if we are in kernel context or user context. This information can be added to the generated profile so users can filter by time spent in kernel or in userspace. This can be done in various ways. A possible approach is to know if we are in kernelspace is to check whether the instruction pointer's most significant bit in kernelspace is set.
- Seems like this issue was also found by Daniel Xu. He wrote about it [in his website](https://dxuuu.xyz/bpf-go-pprof.html).
- [`setitimer(2)`](https://linux.die.net/man/2/setitimer) can be used with `ITIMER_REAL`, which would typically map to "wall time" and `ITIMER_PROF` that tracks CPU time used for both user and kernel space. [Here's how stackprof, a profiler for Ruby sets it](https://github.com/tmm1/stackprof/blob/e26374695343e6eab0d43644f4503391fd1966ed/ext/stackprof/stackprof.c#L210).
- [`timer_create(2)`](https://man7.org/linux/man-pages/man2/timer_create.2.html) is another API to create POSIX timers in a per-process basis. This system call seems to be more fair that signals, as pointed by Felix Geisendörfer with [this reproducer, proftest](https://github.com/felixge/proftest).

Thanks to [Ivo Anjo](https://ivoanjo.me/) for reviewing this post and all the feedback! All errors are mine.