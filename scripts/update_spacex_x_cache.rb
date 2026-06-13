#!/usr/bin/env ruby

require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"
require_relative "spacex_x_card_processor"

TOKEN = ENV["X_BEARER_TOKEN"]
OUTPUT_PATH = File.expand_path(
  ENV.fetch("SPACEX_TV_X_CACHE_PATH", "~/www.sighmon.com/spacex-tv/x-cache.json")
)

COMMON_POST_QUERY = [
  "tweet.fields=created_at,entities,attachments,referenced_tweets",
  "expansions=attachments.media_keys,referenced_tweets.id,referenced_tweets.id.attachments.media_keys",
  "media.fields=type,variants,preview_image_url,url,width,height,media_key,alt_text"
].join("&")

def get_json(url)
  raise "X_BEARER_TOKEN is not set" if TOKEN.nil? || TOKEN.empty?

  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{TOKEN}"

  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    response = http.request(request)
    unless response.code.to_i.between?(200, 299)
      raise "X API HTTP #{response.code}: #{response.body[0, 500]}"
    end

    JSON.parse(response.body)
  end
end

def log(message)
  puts "[#{Time.now.utc.iso8601}] #{message}"
end

begin
  log "Starting SpaceX TV X cache update"

  user = get_json("https://api.x.com/2/users/by/username/spacex?user.fields=pinned_tweet_id")
  user_id = user.fetch("data").fetch("id")
  pinned_tweet_id = user.fetch("data")["pinned_tweet_id"]

  timeline = get_json(
    "https://api.x.com/2/users/#{user_id}/tweets?max_results=25&#{COMMON_POST_QUERY}&exclude=retweets,replies"
  )

  pinned = if pinned_tweet_id && !pinned_tweet_id.empty?
    get_json("https://api.x.com/2/tweets?ids=#{pinned_tweet_id}&#{COMMON_POST_QUERY}")
  end

  existing_cache = if File.file?(OUTPUT_PATH)
    begin
      JSON.parse(File.read(OUTPUT_PATH))
    rescue JSON::ParserError => error
      log "Could not reuse existing processed cards: #{error.message}"
      nil
    end
  end
  processed_cards = SpaceXXCardProcessor.new(
    existing_cache: existing_cache,
    logger: ->(message) { log message }
  ).process(pinned, timeline)
  log "Processed #{processed_cards.fetch("entries").count} broadcast/gallery cards"

  payload = {
    generated_at: Time.now.utc.iso8601,
    source: "x-api-cache-v2",
    user: user,
    pinned: pinned,
    timeline: timeline,
    processed_cards: processed_cards
  }

  FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))
  temporary_path = "#{OUTPUT_PATH}.tmp"
  File.write(temporary_path, JSON.pretty_generate(payload))
  File.rename(temporary_path, OUTPUT_PATH)

  log "Wrote #{OUTPUT_PATH}"
rescue StandardError => error
  log "Failed SpaceX TV X cache update: #{error.class}: #{error.message}"
  raise
end
