---
layout:     post
title:      Building (systems) software with Nix
date:       2026-7-26
author:     Javier Honduvilla Coto
categories: nix build-systems
---


Something I found incredibly frustrating when I started programming was that I could not spend more time building projects and instead had to fight with errors that seemed like a distraction. These major time sinks didn't seem more than an inconvenience that were preventing me from making progress and focus on the _fun stuff_.

Even worse, pretty often what used to work would stop to and it would not be clear why. At the time, I didn't have the knowledge to even hypothesise what might have happened.

Years later, and despite having levelled up as an engineer, I suppose I tend to feel something similar, especially when working on systems software. The project that built or run yesterday is no longer doing so in the same way. Nowadays I can come up with some possible reasons for this, test some theories, and so on, which is neat, but often this is a big time invesment, and more importantly, it's work that I don't find too enjoyable and that takes time from what I want to do: actually building software. The _fun stuff_.

## There you have it, another moving target

Most modern programming languages come with package managers (bundler, cargo, npm, etc) that help fetch dependencies, and among other things they do their best to ensure that they aren't altered without the user knowing. This is essential for security, and also _helps_ to keep consistency across machines. This is a big improvement from how most people were building software not that long ago. 

This is not bullet-proof, though, since there are other sources of variability. The compiler or interpreter version, system-provided libraries, environment variables, etc.

If this weren't enough, when dealing with systems-level software, we might be using native libraries, and exercise the operating system in ways most other software might never do! The more surface area, the higher the chances of the software we depend changing their behaviour over time.

What about our operating system kernel? From an abstract perspective, it's another _library_ that code interfaces with. This leads us to some of the fastest evolving parts in the Linux kernel: the [BPF](https://ebpf.io/) subsystem, the fancy new [sched_ext](https://sched-ext.com/) schedulers, or [io_uring](https://unixism.net/loti/), among others. 

When it comes to the whole operating system, a seemingly scheduled routine system update can update part of the toolchain such as the compiler or the linker. A system library that your code uses might change, or even the kernel itself! This can prevent your code from not building, or even worse: changing its behaviour.

## One of each, please

I haven't checked the data but I would find surprising if the BPF ecosystem is not one of the most fast evolving ones in Linux. This is great, because it means that every kernel release comes with exciting new features and fixes, but it can add spiciness to our development (and production!) environments. Besides that, for a basic [libbpf](https://github.com/libbpf/libbpf) based application written in [Rust](https://github.com/libbpf/libbpf-rs), we depend on:

- Rust compiler (`rustc`) and related tools (`cargo`);
- C compiler(s) (`clang`). Typically BPF code gets compiled with clang, but most Linux systems use `gcc` for other native code;
- Native dependencies (`libelf`, `zlib`, `libbpf`, `libc`);
- Rust dependencies;
- Linux kernel headers (`vmlinux.h`), and, if generated at build time, the system's BTF information and `bpftool` to produce the header file;
- Kernel-side of BPF tooling (system call layer, verifier, etc);
- Static linker(s);
- Dynamic loader (`ld.so`);
- The environment (`env`);

If I were to bet on this list being complete, I would probably lose. But hopefully it's enough to illustrate the problem we are dealing with. 

**We are a single `apt`/`dnf`/`$YOUR_PACKAGE_MANAGER` away from large parts of our software dependencies potentially changing**. By default, it's just one part of the equation that's fully understandable and under our control: the Rust dependencies (assuming there's a Cargo.lock in SCM). Perhaps also `libbpf`, since it's vendored by default. 

If you are unlucky, the burden of hunting for differences is on you. More often that not, figuring out what the previous state of the system was is a herculean task.

## Taming the dependency chaos

One of the core ideas behind modern dependency managers is the inclusion of lockfiles. They represent a serialised view of the dependencies that were "locked in" at some point. Among other data, this includes the package location, its precise version, and a checksum to ensure it's not tampered with or corrupt.

Wouldn't it be neat if we could apply it for all the items in the list above? Turns out there are more than one implementation of this idea, one them being [Nix](https://en.wikipedia.org/wiki/Nix_(package_manager)). Nix is:
- a package manager (provides libraries, binaries, etc);
- a build system (instructions on how to build code);
- a programming language used in the above;
- a Linux distribution, NixOS, based on the eponymous package manager and build system;
- a bunch of infrastructure such as a build farm, cache, etc to support the above;

Here we are referring to the package manager and build system bits, which work in most Linux distributions and other operating systems such as MacOS. In fact, while I have been using these for almost 2 years now, I am a new NixOS user. There is a lot of great content online by folks that know way more about Nix than I do on the language, developer environments, how Nix works under the hood, etc;

For a simplified mental model, the pieces that are useful to know are that the "official" Nix packages are in [this repo called nixpkgs](https://github.com/NixOS/nixpkgs), and that if we want to have something like a Cargo.lock for Nix, we probably want to use [flakes](https://nixos.wiki/wiki/Flakes). By using flakes we can select a particular revision of the nixpkgs repository and every dependency we use will match what's defined and built in it.


## A Rust + BPF environment using Nix

See [`runqslower`, with a Nix flake similar to the one that I use](https://github.com/javierhonduco/blog/tree/b69d44d6be6c953b7868f715bacc35bfdaab1760/code-samples/building-systems-software). I commented it enough to make it more understandable to newcomers, but tried not to be too verbose.

Once Nix in installed, a simple `nix develop` brings an environment with all the required software. The best part is that it's of course reproducible. If it builds and runs now, it will run and build tomorrow. And if it that's not the case, we know that it's due to some other environmental change that's outside of the control of Nix and Cargo.


## Real examples

This is all good, but nothing better than concrete examples on how this setup has helped me so far:

### No more "works in my machine"
Contributors to the projects that use Nix, despite running different ditrubutions or operating systems have a consistent developer environment that very rarely breaks

### Bisecting changes becomes easier
Since the package manager and build system are closely related, bisecting for changes can be a bit easier than what you might be used to. As a real example, the BPF code of one of my projects loaded fine in my kernel if compiled with clang 19 but wasn't accepted if clang 21 was in use.

The code to select a different clang/LLVM version wasn't more than 10 lines of code, and after not too long it was clear that it was [the ISA v3 for BPF becoming a default](https://github.com/llvm/llvm-project/commit/7852ebc088b925ef1c1940cbd56a93d9f8e3e330) which tripped some older kernels/

### Better defaults
One of the projects I use that's written in C++ crashed in production but only under Nix. This is due to a more strict security policy than other software packagers and the usage of `-DD_FORTIFY_SOURCE=2` by default. The undefined behaviour that would have been incredibly tricky to spot, and maybe even caused data corruption, was a clear crash thanks to this flag. This issue was shared upstream and the fix was rolled out some months ago.

### Dependency customisation, without the pain
No need to patch build systems that I might not be familiar with. Additionally Nix derivations, similar to rules if you come from buck2/bazel compose well.

### Faster builds
Thanks to being a proper build system, only what's necessary to be rebuilt is rebuilt. If you are unfamiliar with this concept, think of your favourite spreadsheet software with cells referencing other cells. Only data that needs to be recomputed will be refreshed.

The other source of speed comes from the smart caching that Nix, and other build systems can do thanks to being reproducible. The clang/LLVM bisect didn't rebuild millions of lines of code since there were many cache hits.

## What about the kernel itself?

This write-up is getting a bit long, but that's something I can maybe talk about in a future post if there's interest.

## Conclusion

This setup has helped me focus on the parts that bring me the most joy and has mostly stayed out of my way, which is exactly what you I want in my build systems and package managers.

The Nix ecosystem and tooling is vast and I only know a small fraction of it but I am looking forward to continue using it and learning NixOS.

_Note_: No AI was used in this writing.
