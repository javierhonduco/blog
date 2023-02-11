---
layout:     post
title:      Profiling with signals
date:       2023-2-10
author:     Javier Honduvilla Coto
categories: profiling signals
---

Sampling profilers periodically fetch the stacktrace of the application under observation. Historically, this has been from within the process, in-band,  using signals. There's one dedicated to this sole purpose, `SIGPROF`. We can register a signal handler for it that would retrieve the current stack. Then that stack could be aggregated in place or added to some global data structure and eventually, the generated profile can be written somewhere, such as on disk. Some care has to be taken but this is the general idea of how it works[0].

## Advantages of signal-based profiling

Using signals for profiling has several advantages. We can leverage the existing machinery from your runtime to do most of the heavy lifting. Many programming languages, such as Go or Python, have a standard library function to get the current stack[1]. There is no need to re-implement the stack unwinding mechanism, which is convenient because most languages, particularly high-level ones, don't have a stable stack ABI. We need to account for internal details that might change in future versions.

Another benefit of using signals is that we can make our profiler work across many Unix-like operating systems with the same code.

## Signal-based profiling issues

Unfortunately, signal-based profiling is not without issues. I don't generally recommend it for production usage because the execution path of your application will be altered. When delivering a signal to a process, it will stop whatever it was doing and will start running the profiler code itself. This will happen no matter if your application was busy doing CPU-intensive work, causing a delay in the computation or if it's blocked on IO. In the latter case, it will be scheduled again and a stack will be captured. This is misleading because we might think that the application was burning CPU at the time if we don't carefully analyze the flame graph.

Ideally, when analyzing CPU cycles, if our process is not running in the CPU, a profile should not be captured at all! This is what we call on-CPU profiling, rather than wall-clock profiling, which is what most signal-based profilers do.

### Interrupted system calls

So what happens if we are blocked on IO and a system call arrives? I am glad you ask! Let's check with a small C program:

```shell
$ cat sleepy.c
#include <unistd.h>

int main() {
	sleep(1000);
	return 0;
}
$ make sleepy
cc     sleepy.c   -o sleepy
```

Let's run it while tracing the system calls that it's executing

```shell
$ strace -f ./sleepy
```

After all the work from the dynamic loader, we finally get to the last line

```
clock_nanosleep(CLOCK_REALTIME, 0, {tv_sec=1000, tv_nsec=0},
```

Cool, so this means that we are blocked on this system call. Our OS scheduler will, re-schedule us as soon as the timer's up.


Now let's see what happens when we send `SIGPROF`, ```kill -SIGPROF $(pidof sleepy)```

```
{tv_sec=998, tv_nsec=5246}) = ? ERESTART_RESTARTBLOCK (Interrupted by signal)
[...]
+++ exited with 0 +++
```

It seems like our mighty application died. Turns out that if we didn't set up a signal handler for `SIGPROF`, [the default action is to terminate the process](https://man7.org/linux/man-pages/man7/signal.7.html), so let's fix this by registering a handler:


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

As soon as we run ```kill -SIGPROF $(pidof sleepy)```, the signal is received, and sleep returns with a number bigger than 0, indicating it didn't sleep for as long as it was supposed to:

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
    struct itimerval itimer;
    itimer.it_value.tv_sec = secs;
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

Bear in mind that is is a contrived example where all the userspace threads are blocked, and the kernel barely has to do any work while we are de-scheduled. In other situations, such as multithreaded programs with some threads using CPU might make things a bit more exciting.

### Signals and thread

What about multi-threaded applications? The accounting of CPU that's used when using `setitimer` with SIGPROF is done on a per-process level. We care about which thread runs the signal handler as this might incur a bias on the samples. The [`pthread(7)` manpage](https://linux.die.net/man/7/pthreads) says:

> POSIX.1 distinguishes the notions of signals that are directed to the process as a whole and signals that are directed to individual threads. According to POSIX.1, a process-directed signal (sent using kill(2), for example) should be handled by a single, arbitrarily selected thread within the process. LinuxThreads does not support the notion of process-directed signals: signals may only be sent to specific threads.

This doesn't say much about our situation: signals sent by the kernel sends. Let's add threads to our example above and see what happens.

```patch
+#define WORKERS_COUNT 20

+// Hopefully avoid compiler optimisations.
+int global_counter = 0;

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
    +create_worker();
    [...]
}
```

Running it under `strace` showed that the signal appears to be sent to seemingly arbitrary worker threads. Except for the main thread! This led me to believe that perhaps the scheduler checks for the internal timer data when scheduling a thread, and will deliver a signal if a configured timer is up. Let's bias the workers by having half of them ocassionally sleep.

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
I want to get as much output as possible, quickly, to try to understand which threads might be receiving the signal but `strace` was slowing things down. This is due to not just using `ptrace` underneath, incurring in a couple of extra context switches, but also because threads will be serialized, and our application will effectively become concurrent, but not parallel.

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

Much faster, nice! The logs seem to indicate that we got only even thread IDs, which may indicate that the kernel won't send `SIGPROF` to an arbitrary system call, but to the one consuming quota specified in `setitimer` while accounting for userspace + kernelspace CPU time.


## Signals for profiling beyond the theory

Signal-based profilers have several shortcomings as discussed above. While I was aware of some of these issues, mostly regarding the correctness of the profiles, I had never experienced a production incident caused by them. This is what happened.

We pushed a new version of our Go application to a production-like cluster and some of the processes insta-crashed. They run on Kubernetes, so they were promptly restarted.

For context, Go ships with a signal-based profiler called [`pprof`](https://pkg.go.dev/net/http/pprof). This name is shared by a lot of different things, including the profiler itself, the format of the output it produces, and some of the surrounding tooling. Here, we refer to this profiler implementation.

Our application loads a large BPF program. It used to be rather small, but now it's gotten larger and more complex. BPF programs run in kernel-space, so they have to be deemed safe by the kernel using an included static analyzer called the [BPF verifier](https://docs.kernel.org/bpf/verifier.html). It performs some checks such as ensuring that the program terminates.

After some head scratching, some logs readings, and diving through Go's and the Linux kenel's sources, I started to get an understanding of what was going on.

What happened:
1. We register a `pprof` endpoint. Once it's hit, a signal handler will be set up and `SIGPROF` will be sent to our program;
1. One of the first things we do is load the BPF program. The verifier starts processing our program using quite a bit of kernel CPU cycles for large programs;
    - While this is happening, there's a check to see if there's any pending signal. This is useful to, for example, return to userspace if the user is sending `SIGINT` to the application. When this happens, all the intermediate progress is lost, and we return to the userspace application with `errno == -EINTR`.
1. Now we are back in userspace. We use libbpf to load and manage everything BPF related. When it calls the BPF system call, `bpf(2)`, if it fails with `-EINTR`. It retried the operation up to 5 times, then returns the error;

Turns out we were being interrupted 5 times, so the sixth time wasn't retried again and it errored. We diligently exited when this happened, as we need the BPF program to be loaded to work. The reason why I didn't bump into this locally while working on these feature is that the `pprof` endpoint was never hit but it's periodically called in our production-like environment.

The fix was not hard: [setting the pprof endpoint once the BPF program is loaded](https://github.com/parca-dev/parca-agent/pull/1276).

## Other approaches

Some other profilers follow a debugger-like approach. They read the memory of a target process, from another process (out-of-band). This post is getting a bit too large, so I hope to write about this soon.

## Notes

- [0] [signal-safety(7)](https://man7.org/linux/man-pages/man7/signal-safety.7.html)
- [1] Go's [`PrintStack`](https://pkg.go.dev/runtime/debug#PrintStack) and Ruby's [`Kernel#Caller`](https://ruby-doc.org/3.2.1/Kernel.html#method-i-caller).
- Seems like this issue was also found by Daniel. He wrote about it [in his website](https://dxuuu.xyz/bpf-go-pprof.html).

<!---

==============
learnings

- alarm uses itimer under the hood
- ERESTART_RESTARTBLOCK wtf is this? 2k results on google
- alarm / and SIGPROF print stuff by default
- lol "This timer is useful for profiling in interpreters. The interval timer mechanism does not have the fine granularity necessary for profiling native code."
- multiple threads running: signal seems to arrive to the last (executing) thread


ideas
=====

how signal based profiling works?
who calls the profiling code?
profiling with signals in production

-->
