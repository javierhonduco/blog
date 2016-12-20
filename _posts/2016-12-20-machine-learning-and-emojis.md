---
layout: post
title:  Fun with machine learning and emojis
date:   2016-12-20 8:23:20 +0100
author: Javier Honduvilla Coto
categories: emojis python scikit-learn machine-learning text-mining
---

For the final project of a course on artificial intelligence applications I'm taking in my university we were given total 
freedom to develop whatever we wanted.

After some days thinking about what can I suggest to my team, I thought on *emojis*. I really 💞 emojis. They are an awesome way to 
express oneself in a very nice way.

What if we build a text classifier in which, given a text in english you would get an emoji that suits? 😁
There are a couple of essays and studies on emojis and how they are new _vocabulary_ that we are using and they are way better than 
anything I can write on the topic, so let's get to the meat of the assignment I've coded.

### Fetching tagged text

We needed tagged text as we wanted to do supervised learning, mainly.

We thought on using Twitter. Lots of people use it and write emojis in their tweets! Twitter has a quite nice API to search for tweets
matching some criteria, and that's pretty cool. However, we decided to use Twitter's Streaming API as we could track up to 240 words (or
emojis in this particular case). Those APIs also let you filter by language! Yay!

We tried developing a prototype which can be found in `fetcher/benchmark.py` that we just used as a minimal proof of concept in order
to see how many tweets we were being able to download per second and therefore estimate if we would be able to download a nice amount
of them. We thought that more than 10K tweets would be enough. However, for several reasons that I will explain in the preprocessing 
part, some tweets may be discarded, so we tried to fetch way more.

Once we saw that we were able to download around 9 tweets/s we started refactoring the code and making it more reliable as there are
some exceptions that can be raised from the twitter library we were using, Tweepy. 
We also splitted the network and the I/O part in order to be a bit faster. For that purpose we used two threads, one for each task, as well
as a Python's stdlib thread-safe queue to communicate both threads. 

With that approach, we achieved a slightly higher download rate at around 14tweets/s (yeah, it's possible that disk IO on that laptop
is plain horrible).

We then set up a VM in the cloud(tm) to run this code for 2 days.


### Cleaning up the raw data

Cool. We got more than 2 million tweets weighting around 200MB.

First of all, we cleaned the data doing the following in `preprocessing.py`:
* removing mentions
* removing the `#` in hashtags, as the content may be interesting
* removing "RT"s from manual retweets
* removed hyperlinks
* converted emojis to their names so later processing stages were easier to do
* finally, removed non ASCII characters as we are dealing with english

Then we had something we can starting working on!

With the help of `NLTK` we removed the stopwords, or really common words that aren't really interesting for this problem, 
such as conjunctions and determinants and finally we _stemmed_ them. That means reducing to their root, so for example "calculus" becomes
"calc" as it's going to be better for the classification.

### I dunno what a word is!

That's what most machine learning algorithms say! They only understand numbers 😥. 

But that's not a problem, we can vectorise our text. Here we have used `scikit-learns`'s `TfidfVectorizer` which is a pretty standard
technique in text mining.

We are a bit closer :)

### Algorithm benchmarking

In `sklearn_experiments.py` you can find the `learn_with`, function. It's just a helper that given a classifier and a dataset,
it trains the classifier with part of the dataset, reports the training time and then tests how the model performs with
input that hasn't been used for training. That set is called "test set".

We run that with several algorithms that can be found in the end of the file.

With the reported accuracy and the timing we can get a nice idea on how the different classifiers behave and which one is better for
the problem. We can also tune the parameters passing an optional dict to `learn_with`.

### Conclusion

For an input set of 10.000 tweets, using 8.000 for traning and 2.000 for test, with around 50 different emojis, we got a rough accuracy 
of 40% with a decision tree.

Even thought that our professor liked the result, I was expecting a higher accuracy.

Machine learning is hard, natural language processing is really hard, and those are my baby steps! 😄
