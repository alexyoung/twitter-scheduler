#!/usr/bin/env ruby
require 'optparse'
require 'rubygems'

begin
  require 'openwfe/util/scheduler'
  gem 'twitter4r'
  require 'twitter'
  require 'chronic'
  require 'active_record'
rescue Exception => exception
  puts 'Please install the openwferu-scheduler, chronic, active_record and twitter4r gems and their dependencies.'
  puts exception
  exit
end

options = {}

ARGV.clone.options do |opts|
  script_name = File.basename($0)
  opts.banner = "Usage: #{$0} [options]" 

  opts.separator ""

  opts.on("-u", "--username=username", String, "Your Twitter username") { |o| options['username'] = o }
  opts.on("-p", "--password=password", String, "Your Twitter password") { |o| options['password'] = o }
  opts.on("-t", "--tweet=message", String, "Schedules a tweet") { |o| options['tweet'] = o }
  opts.on("-a", "--at=time", String, "Sets the time to post the tweet") { |o| options['at'] = o }
  opts.on("-d", "--delete=id", String, "Deletes a tweet") { |o| options['delete'] = o }
  opts.on("-l", "--list", "Lists tweets with their IDs") { |o| options['list'] = true }
  opts.on("--help", "-H", "This text") { puts opts; exit 0 }

  opts.parse!
end

if options.empty?
  puts "Run with --help to see how to supply your Twitter username and password."
  puts 'Add a tweet like this: schedule.rb -a 11am -t "Twitter message goes here"'
  puts "Delete one by specifying the ID: schedule.rb -d 1"
  puts "List tweets like this: schedule.rb -l"
  puts "Run with username and password to start the scheduler"
  exit
end

if options.include? 'username'
  @mode = :scheduler
elsif options.include? 'tweet'
  @mode = :add
elsif options.include? 'delete'
  @mode = :delete
elsif options.include? 'list'
  @mode = :list
end

include OpenWFE
scheduler = Scheduler.new
scheduler.start

ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :database => 'tweets.db'
)

class Tweet < ActiveRecord::Base
  def self.install
    return if table_exists?

    ActiveRecord::Schema.define do
      create_table :tweets do |t|
        t.column :message, :string, :limit => 140
        t.column :send_at, :datetime
        t.column :sent, :boolean, :default => false
      end
    end
  end

  def self.upcoming
    find :all, :conditions => ["send_at > ? AND sent = ?", Time.now, false]
  end
end

class Jobs
  def initialize(scheduler, options)
    @jobs = []
    @scheduler = scheduler
    
    @twitter = setup_twitter(options)
  end

  def setup_twitter(options)
    Twitter::Client.new(:login => options['username'], :password => options['password'])
  end

  def <<(job_id)
    @jobs << job_id
  end

  def unschedule(job_id)
    @scheduler.unschedule job_id if job_id
  end

  def unschedule_all
    @jobs.each do |job_id|
      unschedule job_id
    end
    @jobs = []
  end

  def add(time, &block)
    if time and block
      @jobs << @scheduler.schedule_at(time, &block)
    end
  end
  
  def reschedule_tweets
    puts "Rescheduling tweets"

    # Refresh jobs based on the database
    tweets = Tweet.upcoming
    unschedule_all

    tweets.each do |tweet|
      puts "Found tweet: #{tweet.id}: #{tweet.message}, #{tweet.send_at}"
      add tweet.send_at do
        @twitter.status :post, tweet.message
        tweet.update_attribute :sent, true
      end
    end
  end
end

Tweet.install

case @mode
  when :add
    tweet = Tweet.create :message => options['tweet'], :send_at => Chronic.parse(options['at'])
    puts "Added tweet: #{tweet.id}, will send at: #{tweet.send_at}"

  when :list
    Tweet.upcoming.each do |tweet|
      puts "Tweet: #{tweet.id}, will send at: #{tweet.send_at} -- #{tweet.message}"
    end

  when :delete
    tweet = Tweet.find options['delete']
    if tweet
      tweet.destroy
      puts "Deleted"
    else
      puts "Couldn't find tweet with that ID"
    end

  when :scheduler
    jobs = Jobs.new scheduler, options

    # Run once on start
    jobs.reschedule_tweets

    # Reschedule every few minutes
    scheduler.schedule_every '1m' do
      jobs.reschedule_tweets
    end

    scheduler.join
end
