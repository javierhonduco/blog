---
layout: post
title:  "Vectorising Ruby (arrays) for fun and profit"
date:   2016-12-09 08:23:20 +0100
author: Javier Honduvilla Coto
categories: Ruby
---
There are a huge variety of problems that need a pretty high number crunching throughput. Some examples could be rendering, machine learning, digital signal processing, etc.

Last semester I was implementing some correlation pairs algorithm running on the CPU for a parallel computers course where we used several techniques to speed up our code. We made our code multithreaded, pipeline-aware in the best possible way, tried hitting the caches as many times as we could, as well as using vectorised operations.

### What's a vector operation?
Whenever we run an arithmetic operation such as an addition, multiplication, division and so on on the CPU, two operands are needed, and we get a result. Usually, we can do that with a single assembly instruction. We store both operands in CPU's registers, and we obtain the computed value in another one. Those registers can store 32 or 64 bits in the majority of modern computers. So, what do we have to do if we want to perform an arithmetic operation on several numbers? You have probably done this: with a loop :).

Given that this pattern arises quite a lot in the real world, some wider registers, as well as vector operations for them, were created. They allow us to set several numbers in one register (as if they were an array) and perform the operation over them at once, in parallel, resulting in smaller code runtime!

### Example of vector operations in C

### The Ruby C extension

One day, I decided it could be fun trying to implement this as a Ruby C extension! I sketched out the idea: Given a Ruby array, we should be able to sum all of its elements using vector operations. I just decided to implement the summing, but getting other operations to work shouldn't be tough. You can find it here.

### Conclusion

It was my first Ruby extension written in C, and it was a bit tricky at first, I was struggling finding documentation, but I ended finding some very dope extensions people have written that guided me as well as more documentation.

Even though the extension itself it is not very useful, it was fun to tinker with, and I even managed to make it a bit faster! :) I have no idea of C or whatsover, double check this.


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
