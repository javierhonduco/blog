FROM ubuntu:22.10

RUN apt-get update -y --no-install-recommends && \
	apt-get install -yq --no-install-recommends \
	build-essential \
       	ruby-full \
	zlib1g-dev \
	make \
	git \
	ruby-dev

ADD Gemfile Gemfile.lock .
RUN gem install bundler && bundle install

WORKDIR /www
