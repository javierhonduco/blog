---
layout: post
title: It's not a bug, it's an implementation detail
date: 2018-8-30 22:00:00 +0100
author: Javier Honduvilla Coto
categories: SIGSEGV segmentation fault systems programming c JVM Java
---

Working on some eBPF / BCC script that fetches the stacktraces of processes that receive deadly signals I saw dozens of segfaulting Java processes. Despite core dumping was enabled, none was generated.

This is how some of the stacktraces looked like:
```
PID     TID     COMM            FUNC             -
1450691 1450692 java            complete_signal  11
        complete_signal+0x1 [kernel]
        force_sig_info+0xbd [kernel]
        force_sig_info_fault+0x8c [kernel]
        __bad_area_nosemaphore+0xef [kernel]
        bad_area+0x46 [kernel]
        __do_page_fault+0x366 [kernel]
        do_page_fault+0xc [kernel]
        page_fault+0x22 [kernel]
        [unknown]
        [unknown]

451905  451976  java            complete_signal  11
        complete_signal+0x1 [kernel]
        force_sig_info+0xbd [kernel]
        force_sig_info_fault+0x8c [kernel]
        __bad_area_nosemaphore+0xef [kernel]
        bad_area_access_error+0xad [kernel]
        __do_page_fault+0x16b [kernel]
        do_page_fault+0xc [kernel]
        page_fault+0x22 [kernel]
        java.util.logging.Handler.getFilter()+0x38 [perf-451905.map]
        [unknown] [perf-451905.map]
```

My first reaction was thinking that my eBPF code was buggy. I used BCC's `trace.py` to double check, but got the exact same results.

Coming from a Ruby-centric (CRuby / MRI) world full of native extensions, I thought that some Java native extensions could be crashing and that it was somehow quietly handled.

However, it was not a couple of segfaults, it was more like hundreds when invoking some java process like `buck build <...>`!! Even calling `buck help` generated 2 or 3!!

[Chris Down](https://chrisdown.name/) helped me double check that the `trace.py` one-liner[1] made sense. We checked the kernel stacktraces and many of them were pointing to `__bad_area_nosemaphore`.

Gave another go at debugging this in the evening with [Javier Maestro](https://www.linkedin.com/in/jjmaestro) who thought this could be an implementation detail of the Java Virtual Machine. I thought that was completely improbable, but after some more digging into HotSpot's code and [running a Hello World in Java under GDB and seeing that it was receiving a SIGSEGV](https://gist.github.com/javierhonduco/cdaf167fe29ca3c5ada72dea3db7478e), we learnt that it is the way it's supposed to behave (!!!).

Some of the possible cases are:
- The JVM eliminates NULL checks and on SIGSEGV will replace them with the code that has the checks
- The [safepoint execution mechanism](https://chriskirk.blogspot.com/2013/09/what-is-java-safepoint.html)
- We overflowed the stack so it will grow it

The documentation explains [why it works this way and which signals are used for what](http://www.oracle.com/technetwork/java/javase/signals-139944.html).

This function has some interesting logic to check if it's a SIGSEGV with the traditional semantics or not [here](https://github.com/JetBrains/jdk8u_hotspot/blob/d37547149a7c5647ebffbbb62525cc62bd8e2673/src/os_cpu/linux_x86/vm/os_linux_x86.cpp#L296). [The logic for generating a core](https://github.com/JetBrains/jdk8u_hotspot/blob/d37547149a7c5647ebffbbb62525cc62bd8e2673/src/os/posix/vm/os_posix.cpp#L48) which is called [here](https://github.com/JetBrains/jdk8u_hotspot/blob/d37547149a7c5647ebffbbb62525cc62bd8e2673/src/share/vm/utilities/vmError.cpp#L889). We also found some interesting blogpost as well: [http://jcdav.is/2015/10/06/SIGSEGV-as-control-flow/](http://jcdav.is/2015/10/06/SIGSEGV-as-control-flow/)

#### Conclusions
- eBPF is amazing
- Debugging stuff and finding unexpected behaviours with coworkers is fun, thanks you both 💞
- Javier Maestro was right 😜

[1]: ```# trace.py -U 'p::complete_signal(int sig, struct task_struct *p, int group) (sig==11) "%d", sig'```
