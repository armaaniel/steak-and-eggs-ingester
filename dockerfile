FROM ruby:3.4.9-slim-bookworm
RUN apt-get update && apt-get install -y git build-essential libpq-dev
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY ingester.rb .
CMD ["bundle", "exec", "ruby", "ingester.rb"]