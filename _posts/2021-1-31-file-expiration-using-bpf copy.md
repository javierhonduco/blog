---
layout:     post
title:      File expiration using BPF
date:       2021-1-31
author:     Javier Honduvilla Coto
categories: filesystems bpf
---


Most software writes to disk at some point but in some cases nothing cleans up the stale data that won't ever be read again. Engineers working with large scale infrastructure might be familiar with the situation where an engineer, by pure chance, finds out they had several petabytes of old logs that were not deleted.

This is clearly not a great situation for many reasons. When it comes to capacity, the total wasted space might have caused a team to get more machines or increased storage space, increasing the server bill. In the worst case, this caused the re-architecture of some system. This can also be problematic from a legal perspective, as files containing personal information might have to be removed before some date. 

The way most engineers approach file expiration is by using logrotate or similar tools. This works great but it's surprisingly easy to forget to set some new expiration rules for a new or change the path where we write but forget to update the cleanup settings.

## What if filesystems in Linux supported file expiration as some blob storage systems do?

This way we could set a time in the future when the file should be removed and everything will be taken care of for us. If the file is written in a different path it would not be a problem, and no other config would have to be kept in sync.

This could potentially be done at file creation time, or perhaps via another system call or new VFS operation for this purpose. This would be a quite complex project to pull off: from designing a good API, to getting the semantics right, permissions, how logging would be done by the remover thread, to get buy-in from major projects, etc.

The high-level API (being a system call, a library call, or something else) could look like this:

```
expire_file(file: Path, when: Timestamp) -> Result
```

Implementing a prototype in the kernel would be fun, but quite challenging, especially for a kernel noob like me. That's when I thought that this could be approximated with BPF!

Let's reuse an existent system call to replicate the API above. The BPF program would then read the file path and expiration time and store this in a datastore. We could periodically poll the datastore to see which files have to be deleted.

A perfect syscall for this purpose is [`setxattr(2)`](https://man7.org/linux/man-pages/man2/setxattr.2.html) and friends originally intended to set extended attributes on files. These attributes can be seen as a key-value database stored near the file's inodes. They are great for tagging files with different attributes, and one might think... why do we need BPF at all? We could just store the expiration timestamp under a known key. Then, we could periodically explore the filesystem to see which files had to be deleted, no?

This is true but there's an issue: scanning the filesystem, or portions of it will incur in a linear, expensive scan, going through a lot of files that probably we are not going to have to expire. This will pollute the Linux's FS cache, and lots of syscalls will need to be run to traverse the FS and to read the extended attributes.

This is where BPF saves the day. It moves the linear scan of all the files to a more efficient search just within the files that are marked for expiration, thanks to the different design. We can also decide how to index this information, speeding up searches.

The proof of concept of this idea is called sweeper and lives [here](https://github.com/javierhonduco/sweeper). It loads a BPF program that intercepts the setting attributes syscalls. It then sends this information to the userspace driver program written in Rust, which saves it to a SQLite database. Another thread that is periodically woken up queries the database to see which files are due for deletion and removes them.


An application that would like to use sweeper to expire their files would have to set the attribute with key `user.expire_at` and a value of the timestamp when they want their file to be deleted. This is a standard Linux syscall and it's available in many programming language's standard libraries. It could potentially be wrapped in the high-level file access libraries your project might have, all without having to add any external libraries to your software.


## Conclusion

This is just one example of how powerful BPF is, and how can we use it to extend the Linux Kernel or userspace applications in unconventional ways.

Keep in mind that this is just an experiment made for fun and has several major issues. Sweeper needs to be running before you set any attributes. Any expiration requests made before won't be captured. Because of the way the perf buffers (the ring buffer that BPF programs use to send data to userspace, like BCC's [`BPF_PERF_OUTPUT`](https://github.com/iovisor/bcc/blob/cf183b5/docs/reference_guide.md#2-bpf_perf_output) helper) work, data can be discarded so we might miss expiration requests.

Thanks a lot to [Kir Shatrov](http://kirshatrov.com/) for reviewing post!


