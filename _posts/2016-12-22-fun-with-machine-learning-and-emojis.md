---
layout: post
title:  Fun with machine learning and emojis
date:   2016-12-22 8:23:20 +0100
author: Javier Honduvilla Coto
categories: emojis python scikit-learn machine-learning text-mining
---

(**TL;DR**: For a university course I've built a classifier that returns an emoji –that should make sense 😝 – given some input text: [https://github.com/javierhonduco/emoji-prediction](https://github.com/javierhonduco/emoji-prediction))


As the final project of a course on artificial intelligence applications I'm taking at my university we were given total freedom to develop whatever we wanted.

After some days thinking about what could I propose to my team, I thought on **emojis**. I really 💞  emojis. They are an awesome way to express oneself in a very nice way.

So... what if we build a text classifier in which, given a text in English you would get an emoji that suits? 😁

There are a couple of essays and studies on emojis and how they actually are new _vocabulary_ that we are using and they are way better than anything I can write on the topic, so let's get to the steps we did in this assignment.

### Fetching tagged text samples

We needed tagged text as we wanted to do supervised learning, mainly.

Twitter is used by lots of people and many of them write emojis in their tweets! Twitter has a quite nice API to search for tweets matching some criteria, and that's pretty cool. However, we decided to use Twitter's Streaming API as we could track up to 400 words (or emojis in this particular case). Those APIs also let you filter by language! Yay!

We tried developing a prototype which can be found in `fetcher/benchmark.py` that we just used as a minimal proof of concept in order to see how many tweets we were being able to download per second, and therefore, estimate if we would be able to download a reasonable amount of them. We thought that more than 10K tweets would be enough. However, for several reasons that I will explain in the preprocessing part, some tweets may be discarded, so we wanted to fetch way more.

Once we saw that we were able to download around 9 tweets/s we started refactoring the code and making it more reliable as there are some exceptions – mainly networking ones – that can be raised from the twitter library we were using, twython.
We also split the network and the I/O part in order to be a bit faster. For that purpose, we used two threads, one for each task. We used Python's stdlib thread-safe queue as well so both threads could communicate.

With that approach, we achieved a slightly higher download rate at around 14tweets/s (yeah, it's _quite possible_ that disk IO on that laptop is plain horrible 😂 ).

We then set up a VM in the cloud(TM) to run this code for 2 days.


### Cleaning up the raw data

Cool. We got more than 2 million tweets which were around 200MB!! 🎉

First of all, we cleaned the data doing the following in `preprocessing.py`:
* removing mentions
* removing the `#` in hashtags, as the content may be interesting
* removing "RT"s from manual retweets
* removed hyperlinks
* converted emojis to their names so later processing stages were easier to do
* finally, removed non-ASCII characters as we are dealing with English

Then we had something we can starting working on!

With the help of `NLTK` we removed the stopwords, or really common words that aren't really interesting for this problem, such as conjunctions and determinants and finally we _stemmed_ them. Stemming is the process of reducing a word to its root, so for example "calculus" becomes "calc" as it's going to be better for the training process.

### I dunno what a word is!

That's what most machine learning algorithms say! They only understand numbers 😥.

But that's not a problem, we can vectorize our text. Here we have used `scikit-learns`'s `TfidfVectorizer` which is a pretty standard technique in text mining.

We are a bit closer :)

### Algorithm benchmarking

In `sklearn_experiments.py` you can find the `learn_with`, function. It's just a helper that given a classifier and a dataset, it trains the classifier with part of the dataset, reports the training time and then tests how the model performs with input that hasn't been used for training. That set is called "test set".

In order to train it, we run `python sklearn_experiments.py <number_of_tweets>`.

We run that with several algorithms which can be found at the end of the file.

With the reported accuracy and the timing, we can get a nice idea of how the different classifiers behave and which one is better for the problem. We can also tune the parameters passing an optional dictionary to `learn_with`.

### Results & conclusion

With 10.000 tweets – 8k used for training and the rest for test – and about 120 emojis we got these results:


|       Classifier        | Accuracy in test  | Training time           |
|:-----------------------:|:-----------------:|:-----------------------:|
| DecisionTreeClassifier  |       42.75%      |         325.722s        |
| SGDClassifier           |       41.25%      |         119.919s        |
| MultinomialNB           |       35.50%      |          1.687s         |
| GaussianNB              |       34.45%      |          1.882s         |
| SVC with sigmoid kernel |       22.90%      |         892.484s        |


As we can see, our best classifier was the decision tree with an accuracy around 40%!

As we wanted to manually test the trained models with some other inputs we created the `predict` function, which receives 3 arguments:
1. The input text to be classified
2. The vectorized you used during training
3. The trained classifier

Even thought that our professor liked the result, I was expecting a higher accuracy.
Machine learning and natural language processing are hard, but now they look like being loads of fun to me! 😄

### Notes & links

* Don't take this too seriously. I'm not a machine learning expert and probably you can do it in a more efficient, better, more awesome way! Feel free to tell me what could be improved 😁.
* We would have loved trying other techniques such as CNN (Convolutional Neural Networks) as well as other classifiers, but we were too time constrained :sadpanda:.
* Remember that having balanced classes is really important! We maybe noticed a bit late 😓. Too many "😂"s!
* Many tweets have multiples emojis, however we just picked the first one for simplicity's sake.
* `emoji_stats.py` computes the occurences of emojis to get some basic statistics. It uses all the emojis found on a tweet so it can build a "typically those emojis go together" dictionary. That already gives us plenty of information 😄.
* Wonderful libraries/ projects we have used:
  - [scikit-learn](http://scikit-learn.org)
  - [NLTK](http://www.nltk.org/)
  - [Flask](http://flask.pocoo.org/)
  - [numpy](http://www.numpy.org/)
  - [scipy](http://www.scipy.org/)
  - [twython](https://github.com/ryanmcgrath/twython)
  - [emoji lib](https://pypi.python.org/pypi/emoji)
  - [sentry](https://sentry.io) (for error reporting)
  - [Wikipedia's entry on text mining](https://en.wikipedia.org/wiki/Text_mining)
* [The code](https://github.com/javierhonduco/emoji-prediction)
