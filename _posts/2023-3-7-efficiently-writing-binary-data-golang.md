---
layout:     post
title:      Efficiently writing binary data in Go
date:       2023-3-7
author:     Javier Honduvilla Coto
categories: golang go efficiency
---

_Or, speeding up writing binary data in Go by 14x. Code [here](https://github.com/parca-dev/parca-agent/pull/1312)._

On many ocassions, we need to serialise some data structure. For example, when sending information over the network, caching the result of an expensive operation, or when we want compatibility with other runtimes. There are many libraries at our disposal written in C or exposing a C-compliant ABI, such as what we can do in C++, Rust, and many other languages.

> C is the lingua franca of programming

This observation and many other insights from [this blogpost](https://faultlore.com/blah/c-isnt-a-language/) are very interesting.

While sometimes we can avoid having to serialise our data to the format that C deals with by rewriting a piece of code in the language we want to use, sometimes this is unavoidable. Perhaps it would be too big of an effort, or maybe you are dealing with a system call in one of the most popular operation systems, which typically comply with C's view of the world.


## Go's `binary.Write`

Recently at work, I've been working on a new feature in our Golang application. We have a bytes buffer as an argument for a system call. What the program does isn't relevant here, but the important bit is that we need this data to follow C's ABI, as the kernel space implemented in C will have to access it.

Go's standard library has us covered with [`binary.Write`](https://pkg.go.dev/encoding/binary)! It needs a buffer, the endianness of the data, and the data we want to write. We can pass basic data types such as an `int32`, or even structs and it will do the right thing for us.

Seems easy enough. I tested it and everything seemed working correctly. As soon as the PR got approved I wanted to see how it was doing in our cloud environment to ensure that everything was working as expected. The CPU profiles showed a non-trivial amount of CPU cycles spent on these writes. This was a surprise, I thought this operation would be rather cheap, but as it turns out, it's performing allocations!

## Unexpected memory allocations

After inspecting the standard library code, two things stood out. First, there might be some overhead because we are passing a struct rather than basic types and that is done with [a runtime check](https://cs.opensource.google/go/go/+/refs/tags/go1.20.2:src/encoding/binary/binary.go;l=342), but even if that's cheap, [the fast path always allocates](https://cs.opensource.google/go/go/+/refs/tags/go1.20.2:src/encoding/binary/binary.go;l=341) despite having a buffer ready.

I decided to first ship the buffer writes field by field, rather than the whole struct to see the performance gains that would have, and has expected, it was minimal compared to the allocations. Given that we perform many writes to this buffer, these allocations quickly add up.

Were these memory allocations expected? Definitely not by me, but this would not have been the case had I read [the package's documentation](https://pkg.go.dev/encoding/binary):

> This package favors simplicity over efficiency. Clients that require high-performance serialization, especially for large data structures, should look at more advanced solutions such as the encoding/gob package or protocol buffers.

We can't use gob or protobuf here though, we are interoperating with C... Thought that this would be a common problem and indeed I found [some write-ups](https://lemire.me/blog/2022/03/18/writing-out-large-arrays-in-go-binary-write-is-inefficient-for-large-arrays/) describing this same issue.

## A more efficient approach


I wanted to minimising the overhead when writing the different fields of the structs that make this array. Not only lots of allocations are made when writing data we want to pass to the kernel, but also when wanted to zero the buffer to reuse it.

A possibility is to use `binary` helper methods such as `binary.LittleEndian.PutUint64` that don't allocate. The main difference is that they receive a slice rather than a buffer. The first iteration manually sliced every field and wrote to them but this isn't very maintainable, so decided to abstract it in a newly created type creatively named... `EfficientBuffer`!

It looks like this:

```go
type EfficientBuffer []byte

// Slice returns a slice re-sliced from the original EfficientBuffer.
// This is useful to efficiently write byte by byte, for example, when
// setting BPF maps without incurring in extra allocations in the writing
// methods, or changing the capacity of the underlying memory buffer.
//
// Callers are responsible to ensure that there is enough capacity left
// for the passed size.
func (eb *EfficientBuffer) Slice(size int) EfficientBuffer {
	newSize := len(*eb) + size
	subSlice := (*eb)[len(*eb):newSize]
	// Extend its length.
	*eb = (*eb)[:newSize]
	return subSlice
}

// PutUint64 writes the passed uint64 in little
// endian and advances the current slice.
func (eb *EfficientBuffer) PutUint64(v uint64) {
	binary.LittleEndian.PutUint64((*eb)[:8], v)
	*eb = (*eb)[8:]
}

// [...] And other helper methods for other basic types.
```

An ergonomic API that would encapsulate the slicing operations helps making the code more readable. Go's slices and their implementation really helps here and I used some of the tricks you can do with them in this code. It can be used like this:

```go
const (
    sizeOfData = 30 // Size of some C struct, including padding.
)

func main() {
    totalBufferSize := 500
    buf := make(EfficientBuffer, totalBufferSize)
    for i:=0; i<totalBufferSize/sizeOfData; i++ {
        subSlice := buf.Slice(sizeOfStructure)
        // Write the first 64 bit value of some C struct.
        subSlice.PutUint64(i)
    }
}
```

The naming could perhaps be improved. The API assumes that the caller is using space that has been pre-reserved and doesn't do any out-of-bounds check yet, this is something we might improve but in the meantime it allowed us to ship this feature without eating too much from the performance budget which could be better used for other useful features!

## Conclusion

Continuously monitoring our applications in production, including their performance, can help us find issues that were difficult to spot during testing, helping make our software more efficient and reliable. It can also help us challenge our assumptions and understand our languages and runtimes a bit better, which is a great plus! :)
